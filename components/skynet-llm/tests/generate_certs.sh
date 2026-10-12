#!/bin/sh
set -eu
cd "${1:-/fixtures}"
umask 077
openssl req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.pem -days 2 -subj /CN=skynet-llm-test-ca >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -keyout server.key -out server.csr -subj /CN=mock >/dev/null 2>&1
cat > extensions.cnf <<'EOF'
subjectAltName=DNS:mock,DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth
EOF
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -out server.pem -days 1 -extfile extensions.cnf >/dev/null 2>&1
mkdir -p newcerts
: > index.txt
printf '1000\n' > serial
cat > ca.cnf <<'EOF'
[ca]
default_ca=local
[local]
database=index.txt
new_certs_dir=newcerts
certificate=ca.pem
private_key=ca.key
serial=serial
default_md=sha256
policy=policy
x509_extensions=extensions
[policy]
commonName=supplied
[extensions]
subjectAltName=DNS:mock,DNS:localhost,IP:127.0.0.1
extendedKeyUsage=serverAuth
EOF
if ! openssl ca -batch -config ca.cnf -in server.csr -out expired.pem -startdate 20200101000000Z -enddate 20200102000000Z >ca-generation.log 2>&1; then
    cat ca-generation.log >&2
    exit 1
fi
chmod 644 ca.pem server.pem expired.pem
