# MB-POL-02: image repositories keep tags immutable and scan on push.
# NIST SP 800-53: SI-7 (software integrity), RA-5 (vulnerability scanning).
package main

deny contains msg if {
	some rc in resources
	rc.type == "aws_ecr_repository"
	rc.change.after.image_tag_mutability != "IMMUTABLE"
	msg := sprintf("MB-POL-02 %s: image_tag_mutability is %v; must be IMMUTABLE so a released tag cannot be replaced", [rc.address, rc.change.after.image_tag_mutability])
}

deny contains msg if {
	some rc in resources
	rc.type == "aws_ecr_repository"
	not scan_on_push(rc.change.after)
	msg := sprintf("MB-POL-02 %s: scan on push is not enabled", [rc.address])
}

scan_on_push(a) if a.image_scanning_configuration[0].scan_on_push == true
