# MB-POL-09: only verified, immutable images are deployed.
# NIST SP 800-53: SI-7 (software integrity), SR-4 (provenance).
#
# Every container image must be referenced by digest, so what was verified is
# exactly what runs, and the plan must include the signature verification step
# (data.external.image_signature in infra/ecs.tf).
package main

deny contains msg if {
	some rc in task_definitions
	some c in containers(rc)
	not contains(c.image, "@sha256:")
	msg := sprintf("MB-POL-09 %s: container %q image %q is not pinned by digest", [rc.address, c.name, c.image])
}

deny contains msg if {
	some rc in task_definitions
	not signature_verified_in_plan
	msg := sprintf("MB-POL-09 %s: the plan has no image signature verification (data.external.image_signature)", [rc.address])
}

signature_verified_in_plan if {
	some r in input.prior_state.values.root_module.resources
	r.address == "data.external.image_signature[0]"
	r.values.result.verified == "true"
}

signature_verified_in_plan if {
	some rc in input.resource_changes
	rc.address == "data.external.image_signature[0]"
	rc.change.actions == ["read"]
}
