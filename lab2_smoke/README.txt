Smoke validation for Lab 2.

Validated chain:
- root: slhdsashake192s
- intermediate: mldsa65
- leaf: mldsa65

Observed DER sizes:
- root_slh.crt: 16552 bytes
- int_ml.crt: 18467 bytes
- server_ml.crt: 5587 bytes

Verification result:
- openssl verify with root as trust anchor and intermediate as untrusted chain: OK
