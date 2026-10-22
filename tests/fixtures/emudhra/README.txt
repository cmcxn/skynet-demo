Certificate chains served by the eMudhra test hosts
====================================================

Each file holds the full chain sent by one of the test hosts at
https://emudhra.we-have-a-problem.com/, in PEM format, leaf first.
The chains were captured on 20 October 2026.

  <kind>-<gen>-emudhra.we-have-a-problem.com.pem
      leaf, impacted intermediate, emSign Root TLS CA - G3 (cross-signed
      by emSign ECC Root CA - G3)

  <kind>-<gen>-aaa-emudhra.we-have-a-problem.com.pem
      leaf, impacted intermediate cross-signed by AAA Certificate Services

where <kind> is dv, ov or ev and <gen> is g3b or g3c.

Offline check
-------------

To see whether a trust store still accepts a chain, verify the leaf
against that store using the rest of the file as untrusted intermediates.
For the OpenSSL default store:

  openssl verify -show_chain -untrusted FILE.pem FILE.pem

For a specific bundle:

  openssl verify -show_chain -CAfile /path/to/bundle.pem -untrusted FILE.pem FILE.pem

"OK" means the store still trusts the compromised intermediate.
An error naming the issuer certificate means trust has been removed.
Note that openssl verify does not check revocation unless asked to.

Source: https://emudhra.we-have-a-problem.com/chains.zip
Retrieved: 2026-10-22. Public certificates only; no private keys.
Archive SHA-256: 8a2edc81b6c51e3ad27d45ca1e441ec84c961e2dee0fc547f2a02c0f74315f95
Regression checks use a fixed verification time within the leaf validity period.

Positive control: trusted-isrg-root-x1.crt is the unaffected ISRG Root X1,
from Debian ca-certificates 20250419+deb13u1 (Mozilla root set).
It must remain accepted so an unrelated-only bundle cannot pass.
