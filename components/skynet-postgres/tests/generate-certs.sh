#!/bin/sh
set -eu
cd "$1"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=Postgres-Test-CA -keyout ca.key -out ca.crt >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=Wrong-CA -keyout wrong-ca.key -out wrong-ca.crt >/dev/null 2>&1
openssl req -newkey rsa:2048 -nodes -subj /CN=db.test -keyout server.key -out server.csr >/dev/null 2>&1
printf 'subjectAltName=DNS:db.test,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' > server.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 2 -extfile server.ext -out server.crt >/dev/null 2>&1
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -not_before 20200101000000Z -not_after 20200102000000Z -extfile server.ext -out expired.crt >/dev/null 2>&1
# Copy into the DB container with its postgres owner, rather than changing host ownership.
chmod 644 ./*.crt
