local json = require "skynet_llm.json"
local M = {}
local function object(v) return json.kind(v) == "object" end
local function array(v) return json.kind(v) == "array" end
local function finite(v) return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge end
local function integer(v) return finite(v) and v >= 0 and v % 1 == 0 end
local function failure(message,request)
    return nil,{code=request and "invalid_request" or "invalid_response",stage=request and "validate" or "protocol",message=message,retryable=false}
end
local function tokens(v)
    if not array(v) or #v == 0 then return false end
    for _, token in ipairs(v) do if not integer(token) then return false end end
    return true
end
local function input_count(input)
    if type(input) == "string" then if #input > 0 then return 1 end; return nil end
    if not array(input) or #input == 0 then return nil end
    if type(input[1]) == "number" then if tokens(input) then return 1 end; return nil end
    local strings=type(input[1]) == "string"
    for _, value in ipairs(input) do
        if strings then if type(value) ~= "string" or #value == 0 then return nil end
        elseif not tokens(value) then return nil end
    end
    return #input
end

function M.validate_request(body,profile,options)
    if not object(body) or type(body.model) ~= "string" or #body.model == 0 or not input_count(body.input) then return failure("embeddings requires model and nonempty homogeneous input",true) end
    if body.encoding_format ~= nil and body.encoding_format ~= "float" and body.encoding_format ~= "base64" then return failure("encoding_format must be float or base64",true) end
    if body.dimensions ~= nil and (not integer(body.dimensions) or body.dimensions == 0) then return failure("dimensions must be a positive integer",true) end
    if body.stream ~= nil and body.stream ~= false then return failure("embeddings does not support stream",true) end
    if options and options.expected_dimensions ~= nil and (not integer(options.expected_dimensions) or options.expected_dimensions == 0) then return failure("expected_dimensions must be a positive integer",true) end
    return true
end

local alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local base64_values={}
for i=1,#alphabet do base64_values[alphabet:sub(i,i)]=i-1 end
local function base64_vector(source)
    if type(source) ~= "string" or #source == 0 or #source % 4 ~= 0 then return nil,"invalid base64 length" end
    local chunks={}
    for i=1,#source,4 do
        local ca,cb,cc,cd=source:sub(i,i),source:sub(i+1,i+1),source:sub(i+2,i+2),source:sub(i+3,i+3)
        local a,b,c,d=base64_values[ca],base64_values[cb],base64_values[cc],base64_values[cd]
        if not a or not b then return nil,"invalid base64 alphabet" end
        if cc == "=" then
            if cd ~= "=" or i+3 ~= #source or b % 16 ~= 0 then return nil,"invalid base64 padding" end
            chunks[#chunks+1]=string.char((a << 2) | (b >> 4))
        elseif cd == "=" then
            if not c or i+3 ~= #source or c % 4 ~= 0 then return nil,"invalid base64 padding" end
            chunks[#chunks+1]=string.char((a << 2) | (b >> 4),((b & 15) << 4) | (c >> 2))
        else
            if not c or not d then return nil,"invalid base64 alphabet" end
            chunks[#chunks+1]=string.char((a << 2) | (b >> 4),((b & 15) << 4) | (c >> 2),((c & 3) << 6) | d)
        end
    end
    local bytes=table.concat(chunks)
    if #bytes == 0 or #bytes % 4 ~= 0 then return nil,"base64 must contain whole float32 values" end
    local values=json.array{}
    for i=1,#bytes,4 do
        local value=string.unpack("<f",bytes,i)
        if not finite(value) then return nil,"nonfinite float32 embedding" end
        values[#values+1]=value
    end
    return values
end

local function collect(data,count,dimensions,encoding)
    if not object(data) or not array(data.data) or #data.data == 0 then return failure("embedding data must be a nonempty array") end
    count=count or #data.data
    if #data.data ~= count then return failure("embedding count does not match input") end
    local vectors=json.array{}; local width
    for _, item in ipairs(data.data) do
        if not object(item) or not integer(item.index) or item.index >= count or vectors[item.index+1] ~= nil then return failure("invalid or duplicate embedding index") end
        local values,message
        if type(item.embedding) == "string" then
            if encoding == "float" then return failure("expected float embedding") end
            values,message=base64_vector(item.embedding)
            if not values then return failure(message) end
        else
            if encoding == "base64" or not array(item.embedding) or #item.embedding == 0 then return failure("invalid embedding vector") end
            values=json.array{}
            for _, value in ipairs(item.embedding) do
                if not finite(value) then return failure("nonfinite embedding value") end
                values[#values+1]=value
            end
        end
        if width and width ~= #values then return failure("inconsistent embedding dimensions") end
        width=#values
        if dimensions and width ~= dimensions then return failure("embedding dimensions do not match expected_dimensions") end
        vectors[item.index+1]=values
    end
    for i=1,count do if not vectors[i] then return failure("missing embedding index") end end
    return vectors
end

function M.validate_response(body,data,options)
    local count=body and input_count(body.input)
    if not count then return failure("invalid original embedding input") end
    local dimensions=options and options.expected_dimensions
    if dimensions ~= nil and (not integer(dimensions) or dimensions == 0) then return failure("invalid expected_dimensions") end
    local values,err=collect(data,count,dimensions,(body and body.encoding_format) or "float")
    if not values then return nil,err end
    return true
end

-- Native response or public {data=native_response}; keeps native index order intact.
function M.vectors(res)
    local data=res
    if object(res) and object(res.data) then data=res.data end
    return collect(data)
end

return M
