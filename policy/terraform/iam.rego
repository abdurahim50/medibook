# MB-POL-03: identity policies follow least privilege.
# NIST SP 800-53: AC-6 (least privilege).
#
# Checked: inline and managed identity policies. Not checked: resource policies
# (KMS key, SNS topic), where "Resource": "*" means "this resource".
package main

identity_policy_types := {"aws_iam_role_policy", "aws_iam_policy", "aws_iam_user_policy", "aws_iam_group_policy"}

# Actions that AWS does not allow to be scoped to a resource.
resource_star_allowed := {"ecr:GetAuthorizationToken", "sts:GetCallerIdentity"}

allow_statements(rc) := [s |
	doc := json.unmarshal(rc.change.after.policy)
	some s in as_list(doc.Statement)
	s.Effect == "Allow"
]

deny contains msg if {
	some rc in resources
	rc.type in identity_policy_types
	not unknown(rc, "policy")
	some s in allow_statements(rc)
	some action in as_list(s.Action)
	wildcard_action(action)
	msg := sprintf("MB-POL-03 %s: allows action %q; grant specific actions", [rc.address, action])
}

deny contains msg if {
	some rc in resources
	rc.type in identity_policy_types
	not unknown(rc, "policy")
	some s in allow_statements(rc)
	s.NotAction
	msg := sprintf("MB-POL-03 %s: Allow with NotAction grants everything except the listed actions; list allowed actions instead", [rc.address])
}

deny contains msg if {
	some rc in resources
	rc.type in identity_policy_types
	not unknown(rc, "policy")
	some s in allow_statements(rc)
	"*" in as_list(s.Resource)
	some action in as_list(s.Action)
	not action in resource_star_allowed
	msg := sprintf("MB-POL-03 %s: allows %q on every resource; scope it to specific ARNs", [rc.address, action])
}

warn contains msg if {
	some rc in resources
	rc.type in identity_policy_types
	unknown(rc, "policy")
	msg := sprintf("MB-POL-03 %s: final policy JSON is known only after apply; its aws_iam_policy_document statements are checked instead", [rc.address])
}

wildcard_action(action) if action == "*"

wildcard_action(action) if endswith(action, ":*")

# ---------- aws_iam_policy_document data sources ----------
# A policy that references a resource created in the same plan (for example a
# log group ARN) is unknown at plan time, so the checks above cannot see it.
# The policy document data source it is built from still has its actions in
# the plan, so the same rules are applied to it.
#
# Statements with principals are resource or trust policies (KMS key, SNS topic,
# assume-role), where "Resource": "*" means "this resource"; they are skipped.

# Documents read during apply (inputs not yet known).
document_statements contains {"address": rc.address, "statement": s, "resources_unknown": resources_unknown} if {
	some rc in input.resource_changes
	rc.mode == "data"
	rc.type == "aws_iam_policy_document"
	some i, s in object.get(rc.change, "after", {}).statement
	resources_unknown := object.get(rc.change.after_unknown, ["statement", i, "resources"], false)
}

# Documents already read during plan (all inputs known).
document_statements contains {"address": r.address, "statement": s, "resources_unknown": false} if {
	some r in input.prior_state.values.root_module.resources
	r.mode == "data"
	r.type == "aws_iam_policy_document"
	some s in r.values.statement
}

identity_statements contains d if {
	some d in document_statements
	object.get(d.statement, "effect", "Allow") in {"Allow", null}
	count(non_null(object.get(d.statement, "principals", []))) == 0
	count(non_null(object.get(d.statement, "not_principals", []))) == 0
}

non_null(x) := [] if x == null

non_null(x) := x if x != null

deny contains msg if {
	some d in identity_statements
	some action in non_null(object.get(d.statement, "actions", []))
	wildcard_action(action)
	msg := sprintf("MB-POL-03 %s: allows action %q; grant specific actions", [d.address, action])
}

deny contains msg if {
	some d in identity_statements
	count(non_null(object.get(d.statement, "not_actions", []))) > 0
	msg := sprintf("MB-POL-03 %s: Allow with not_actions grants everything except the listed actions; list allowed actions instead", [d.address])
}

deny contains msg if {
	some d in identity_statements
	d.resources_unknown == false
	"*" in non_null(object.get(d.statement, "resources", []))
	some action in non_null(object.get(d.statement, "actions", []))
	not action in resource_star_allowed
	msg := sprintf("MB-POL-03 %s: allows %q on every resource; scope it to specific ARNs", [d.address, action])
}
