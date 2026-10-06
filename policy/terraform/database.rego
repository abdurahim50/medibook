# MB-POL-10: databases are private, encrypted, backed up and keep no password in Terraform.
# NIST SP 800-53: SC-7 (boundary protection), SC-28 (protection at rest),
# CP-9 (system backup), IA-5 (authenticator management), SC-8 (transmission).
package main

deny contains msg if {
	some rc in resources
	rc.type == "aws_db_instance"
	not rc.change.after.storage_encrypted == true
	msg := sprintf("MB-POL-10 %s: storage_encrypted must be true", [rc.address])
}

deny contains msg if {
	some rc in resources
	rc.type == "aws_db_instance"
	rc.change.after.publicly_accessible == true
	msg := sprintf("MB-POL-10 %s: publicly_accessible must be false", [rc.address])
}

deny contains msg if {
	some rc in resources
	rc.type == "aws_db_instance"
	not object.get(rc.change.after, "backup_retention_period", 0) >= 7
	msg := sprintf("MB-POL-10 %s: backup_retention_period must be at least 7 days (point-in-time recovery)", [rc.address])
}

deny contains msg if {
	some rc in resources
	rc.type == "aws_db_instance"
	not rc.change.after.manage_master_user_password == true
	msg := sprintf("MB-POL-10 %s: set manage_master_user_password = true so RDS keeps the password in Secrets Manager, never in Terraform code or state", [rc.address])
}

deny contains msg if {
	some rc in resources
	rc.type == "aws_db_parameter_group"
	startswith(object.get(rc.change.after, "family", ""), "postgres")
	not forces_tls(rc.change.after)
	msg := sprintf("MB-POL-10 %s: set rds.force_ssl = 1 so every connection uses TLS", [rc.address])
}

forces_tls(pg) if {
	some p in pg.parameter
	p.name == "rds.force_ssl"
	p.value == "1"
}
