# MB-POL-04: containers run hardened.
# NIST SP 800-53: CM-6 (configuration settings), CM-7 (least functionality).
package main

containers(rc) := json.unmarshal(rc.change.after.container_definitions)

task_definitions contains rc if {
	some rc in resources
	rc.type == "aws_ecs_task_definition"
	not unknown(rc, "container_definitions")
}

deny contains msg if {
	some rc in task_definitions
	some c in containers(rc)
	not c.readonlyRootFilesystem == true
	msg := sprintf("MB-POL-04 %s: container %q must set readonlyRootFilesystem = true", [rc.address, c.name])
}

deny contains msg if {
	some rc in task_definitions
	some c in containers(rc)
	not non_root_user(c)
	msg := sprintf("MB-POL-04 %s: container %q must run as a non-root user (set user to a UID other than 0)", [rc.address, c.name])
}

deny contains msg if {
	some rc in task_definitions
	some c in containers(rc)
	c.privileged == true
	msg := sprintf("MB-POL-04 %s: container %q must not be privileged", [rc.address, c.name])
}

deny contains msg if {
	some rc in task_definitions
	some c in containers(rc)
	not "ALL" in object.get(c, ["linuxParameters", "capabilities", "drop"], [])
	msg := sprintf("MB-POL-04 %s: container %q must drop all Linux capabilities", [rc.address, c.name])
}

warn contains msg if {
	some rc in resources
	rc.type == "aws_ecs_task_definition"
	unknown(rc, "container_definitions")
	msg := sprintf("MB-POL-04 %s: container definitions known only after apply; not evaluated", [rc.address])
}

# The image's USER is not visible in the plan, so the task must set it explicitly.
non_root_user(c) if {
	user := split(c.user, ":")[0]
	user != ""
	not user in {"0", "root"}
}
