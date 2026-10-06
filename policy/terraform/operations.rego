# MB-POL-05: log groups have a retention period.
# NIST SP 800-53: AU-11 (audit record retention).
#
# MB-POL-06: every taggable resource carries the Project tag.
# NIST SP 800-53: CM-8 (system component inventory).
#
# MB-POL-07: application load balancers drop invalid HTTP headers.
# NIST SP 800-53: SC-7, SI-10 (information input validation).
#
# MB-POL-08: SNS topics are encrypted with a KMS key.
# NIST SP 800-53: SC-28 (protection of information at rest).
package main

deny contains msg if {
	some rc in resources
	rc.type == "aws_cloudwatch_log_group"
	not object.get(rc.change.after, "retention_in_days", 0) > 0
	msg := sprintf("MB-POL-05 %s: retention_in_days is not set; logs would be kept forever and billed forever", [rc.address])
}

deny contains msg if {
	some rc in resources
	"tags_all" in object.keys(rc.change.after)
	not unknown(rc, "tags_all")
	not rc.change.after.tags_all.Project
	msg := sprintf("MB-POL-06 %s: missing the Project tag (set it through the provider's default_tags)", [rc.address])
}

deny contains msg if {
	some rc in resources
	rc.type in {"aws_lb", "aws_alb"}
	object.get(rc.change.after, "load_balancer_type", "application") == "application"
	not rc.change.after.drop_invalid_header_fields == true
	msg := sprintf("MB-POL-07 %s: drop_invalid_header_fields must be true (request smuggling protection)", [rc.address])
}

deny contains msg if {
	some rc in resources
	rc.type == "aws_sns_topic"
	not unknown(rc, "kms_master_key_id")
	object.get(rc.change.after, "kms_master_key_id", "") in {"", null}
	msg := sprintf("MB-POL-08 %s: topic is not encrypted; set kms_master_key_id", [rc.address])
}
