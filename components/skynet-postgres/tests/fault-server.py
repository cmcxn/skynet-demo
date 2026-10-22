"""Loopback/test-network-only PostgreSQL protocol faults; no real credentials."""
import socketserver, threading, time, ssl, struct
class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(3)
        try:
            def readn(n):
                data=b''
                while len(data)<n:
                    part=self.request.recv(n-len(data))
                    if not part: raise OSError('closed')
                    data+=part
                return data
            port=self.server.server_address[1]
            if port in (15437,15438,15439):
                size=struct.unpack('!I',readn(4))[0];readn(size-4)
                def auth(code,payload):
                    body=struct.pack('!I',code)+payload
                    self.request.sendall(b'R'+struct.pack('!I',len(body)+4)+body)
                if port==15439:
                    auth(10,b'SCRAM-SHA-256-PLUS\0\0'); return
                auth(10,b'SCRAM-SHA-256\0\0')
                prefix=readn(5);msg=readn(struct.unpack('!I',prefix[1:])[0]-4)
                nonce=msg.split(b'r=',1)[1]
                if port==15437: response=b'r=bad-nonce,s=c2FsdA==,i=4096'
                else: response=b'r='+nonce+b'extension,s=c2FsdA==,i=1000001'
                auth(11,response);time.sleep(.2);return
            self.request.recv(8192)
            if self.server.server_address[1] == 15432: self.request.sendall(b'N')
            elif self.server.server_address[1] == 15434: self.request.sendall(b'S'); time.sleep(2)
            elif self.server.server_address[1] == 15436:
                self.request.sendall(b'S')
                context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                context.load_cert_chain('/fixtures/expired.crt','/fixtures/server.key')
                with context.wrap_socket(self.request,server_side=True) as conn: conn.recv(8192)
            elif self.server.server_address[1] == 15435: self.request.sendall(b'R\x00\x00\x00\x08\x00')
            else: time.sleep(2)
        except OSError: pass
class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address=True
    daemon_threads=True
for port in (15432,15433,15434,15435,15436,15437,15438,15439):
    server=Server(('0.0.0.0',port),Handler)
    threading.Thread(target=server.serve_forever,daemon=True).start()
threading.Event().wait()
