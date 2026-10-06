# Shared helpers for the Terraform plan policies.
#
# Input: the JSON form of a saved plan (terraform show -json plan.tfplan).
# Every rule looks at resource_changes, which lists each managed resource with
# its planned values (change.after) and which of those values are not known
# until apply (change.after_unknown).
package main

# Managed resources that will exist after apply. Deleted resources are skipped;
# unchanged (no-op) resources are included, so the whole stack is checked,
# not only the diff.
resources contains rc if {
	some rc in input.resource_changes
	rc.mode == "managed"
	rc.change.actions != ["delete"]
	rc.change.after != null
}

# True when Terraform cannot know a value until apply (for example an ARN of a
# resource that is created in the same plan). Rules warn instead of guessing.
unknown(rc, field) if rc.change.after_unknown[field] == true

# Accept a JSON value that may be a single item or a list.
as_list(x) := x if is_array(x)

as_list(x) := [x] if not is_array(x)
