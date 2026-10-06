# Certificates

`rds-global-bundle.pem` holds the Amazon RDS root and intermediate certificate authorities for all commercial regions. The API connects to RDS with `PGSSLMODE=verify-full`, which checks that the server certificate chains to one of these authorities and matches the database hostname, so a connection cannot be intercepted by an impersonating server.

- Source: <https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem> ([AWS documentation](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/UsingWithRDS.SSL.html))
- These are public certificates, not secrets.
- To update: download the file again, review the diff, and commit it in a pull request. The SHA-256 of the committed file is recorded in the commit that adds or changes it.
