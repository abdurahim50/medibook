# Unit tests for the plan policies. Run: conftest verify --policy policy/terraform
package main

tags := {"Project": "medibook"}

plan(rcs) := {"resource_changes": rcs}

change(type, after) := change_with(type, after, {}, ["create"])

change_with(type, after, unknown_fields, actions) := {
	"address": sprintf("%s.test", [type]),
	"mode": "managed",
	"type": type,
	"change": {"actions": actions, "after": after, "after_unknown": unknown_fields},
}

has_rule(denials, id) if {
	some msg in denials
	startswith(msg, id)
}

# ---------- MB-POL-01 network ----------

test_ingress_https_from_internet_allowed if {
	count(deny) == 0 with input as plan([change("aws_vpc_security_group_ingress_rule", {"cidr_ipv4": "0.0.0.0/0", "ip_protocol": "tcp", "from_port": 443, "to_port": 443, "tags_all": tags})])
}

test_ingress_restricted_cidr_any_port_allowed if {
	count(deny) == 0 with input as plan([change("aws_vpc_security_group_ingress_rule", {"cidr_ipv4": "198.51.100.23/32", "ip_protocol": "tcp", "from_port": 22, "to_port": 22, "tags_all": tags})])
}

test_ingress_all_protocols_from_internet_denied if {
	has_rule(deny, "MB-POL-01") with input as plan([change("aws_vpc_security_group_ingress_rule", {"cidr_ipv4": "0.0.0.0/0", "ip_protocol": "-1", "from_port": null, "to_port": null, "tags_all": tags})])
}

test_ingress_ipv6_ssh_denied if {
	has_rule(deny, "MB-POL-01") with input as plan([change("aws_vpc_security_group_ingress_rule", {"cidr_ipv6": "::/0", "ip_protocol": "tcp", "from_port": 22, "to_port": 22, "tags_all": tags})])
}

test_ingress_port_range_including_80_denied if {
	has_rule(deny, "MB-POL-01") with input as plan([change("aws_vpc_security_group_ingress_rule", {"cidr_ipv4": "0.0.0.0/0", "ip_protocol": "tcp", "from_port": 0, "to_port": 65535, "tags_all": tags})])
}

test_legacy_security_group_rule_denied if {
	has_rule(deny, "MB-POL-01") with input as plan([change("aws_security_group_rule", {"type": "ingress", "cidr_blocks": ["0.0.0.0/0"], "from_port": 5432, "to_port": 5432})])
}

test_legacy_egress_rule_ignored if {
	count(deny) == 0 with input as plan([change("aws_security_group_rule", {"type": "egress", "cidr_blocks": ["0.0.0.0/0"], "from_port": 0, "to_port": 0})])
}

test_inline_ingress_block_denied if {
	has_rule(deny, "MB-POL-01") with input as plan([change("aws_security_group", {"ingress": [{"cidr_blocks": ["0.0.0.0/0"], "from_port": 3389, "to_port": 3389}], "tags_all": tags})])
}

test_deleted_resource_ignored if {
	count(deny) == 0 with input as plan([change_with("aws_vpc_security_group_ingress_rule", null, {}, ["delete"])])
}

# ---------- MB-POL-02 registry ----------

test_ecr_immutable_with_scan_allowed if {
	count(deny) == 0 with input as plan([change("aws_ecr_repository", {"image_tag_mutability": "IMMUTABLE", "image_scanning_configuration": [{"scan_on_push": true}], "tags_all": tags})])
}

test_ecr_immutable_with_exclusion_denied if {
	has_rule(deny, "MB-POL-02") with input as plan([change("aws_ecr_repository", {"image_tag_mutability": "IMMUTABLE_WITH_EXCLUSION", "image_scanning_configuration": [{"scan_on_push": true}], "tags_all": tags})])
}

test_ecr_missing_scan_block_denied if {
	has_rule(deny, "MB-POL-02") with input as plan([change("aws_ecr_repository", {"image_tag_mutability": "IMMUTABLE", "image_scanning_configuration": [], "tags_all": tags})])
}

# ---------- MB-POL-03 IAM ----------

iam(doc) := change("aws_iam_role_policy", {"policy": json.marshal(doc)})

test_get_authorization_token_on_star_allowed if {
	count(deny) == 0 with input as plan([iam({"Statement": [{"Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*"}]})])
}

test_scoped_policy_allowed if {
	count(deny) == 0 with input as plan([iam({"Statement": [{"Effect": "Allow", "Action": ["logs:PutLogEvents"], "Resource": ["arn:aws:logs:us-east-1:111122223333:log-group:x:*"]}]})])
}

test_admin_policy_denied if {
	has_rule(deny, "MB-POL-03") with input as plan([iam({"Statement": {"Effect": "Allow", "Action": "*", "Resource": "*"}})])
}

test_service_wildcard_on_scoped_resource_denied if {
	has_rule(deny, "MB-POL-03") with input as plan([iam({"Statement": [{"Effect": "Allow", "Action": "ecr:*", "Resource": "arn:aws:ecr:us-east-1:111122223333:repository/x"}]})])
}

test_specific_action_on_star_denied if {
	has_rule(deny, "MB-POL-03") with input as plan([iam({"Statement": [{"Effect": "Allow", "Action": "s3:GetObject", "Resource": "*"}]})])
}

test_not_action_denied if {
	has_rule(deny, "MB-POL-03") with input as plan([iam({"Statement": [{"Effect": "Allow", "NotAction": "iam:*", "Resource": "*"}]})])
}

test_deny_statement_with_wildcards_allowed if {
	count(deny) == 0 with input as plan([iam({"Statement": [{"Effect": "Deny", "Action": "*", "Resource": "*"}]})])
}

test_unknown_policy_warns_not_denies if {
	rcs := [change_with("aws_iam_role_policy", {}, {"policy": true}, ["create"])]
	count(deny) == 0 with input as plan(rcs)
	count(warn) == 1 with input as plan(rcs)
}

# ---------- MB-POL-04 containers ----------

task(c) := change("aws_ecs_task_definition", {"container_definitions": json.marshal([c]), "tags_all": tags})

hardened := {"name": "api", "user": "10001:10001", "readonlyRootFilesystem": true, "linuxParameters": {"capabilities": {"drop": ["ALL"]}}}

test_hardened_container_allowed if {
	count(deny) == 0 with input as {"resource_changes": [task(pinned)], "prior_state": verified_state}
}

test_missing_user_denied if {
	has_rule(deny, "MB-POL-04") with input as plan([task(object.remove(hardened, ["user"]))])
}

test_root_user_by_name_denied if {
	has_rule(deny, "MB-POL-04") with input as plan([task(object.union(hardened, {"user": "root:root"}))])
}

test_writable_root_filesystem_denied if {
	has_rule(deny, "MB-POL-04") with input as plan([task(object.remove(hardened, ["readonlyRootFilesystem"]))])
}

test_capabilities_not_dropped_denied if {
	has_rule(deny, "MB-POL-04") with input as plan([task(object.remove(hardened, ["linuxParameters"]))])
}

# ---------- MB-POL-05 to MB-POL-08 ----------

test_log_group_without_retention_denied if {
	has_rule(deny, "MB-POL-05") with input as plan([change("aws_cloudwatch_log_group", {"name": "x", "tags_all": tags})])
}

test_missing_project_tag_denied if {
	has_rule(deny, "MB-POL-06") with input as plan([change("aws_cloudwatch_log_group", {"retention_in_days": 7, "tags_all": {}})])
}

test_null_tags_denied if {
	has_rule(deny, "MB-POL-06") with input as plan([change("aws_cloudwatch_log_group", {"retention_in_days": 7, "tags_all": null})])
}

test_untaggable_resource_ignored if {
	count(deny) == 0 with input as plan([change("aws_route_table_association", {"subnet_id": "subnet-1"})])
}

test_network_load_balancer_not_checked_for_headers if {
	count(deny) == 0 with input as plan([change("aws_lb", {"load_balancer_type": "network", "tags_all": tags})])
}

test_alb_keeping_invalid_headers_denied if {
	has_rule(deny, "MB-POL-07") with input as plan([change("aws_lb", {"load_balancer_type": "application", "drop_invalid_header_fields": false, "tags_all": tags})])
}

test_sns_key_from_same_plan_allowed if {
	count(deny) == 0 with input as plan([change_with("aws_sns_topic", {"tags_all": tags}, {"kms_master_key_id": true}, ["create"])])
}

test_unencrypted_sns_denied if {
	has_rule(deny, "MB-POL-08") with input as plan([change("aws_sns_topic", {"tags_all": tags})])
}

# ---------- Scope ----------

test_data_sources_ignored if {
	rc := object.union(change("aws_iam_policy", {"policy": "{\"Statement\":{\"Effect\":\"Allow\",\"Action\":\"*\",\"Resource\":\"*\"}}"}), {"mode": "data"})
	count(deny) == 0 with input as plan([rc])
}

# ---------- MB-POL-03 policy documents ----------

doc_read(statements, unknown_fields) := {
	"address": "data.aws_iam_policy_document.test",
	"mode": "data",
	"type": "aws_iam_policy_document",
	"change": {"actions": ["read"], "after": {"statement": statements}, "after_unknown": unknown_fields},
}

doc_in_state(statements) := {"prior_state": {"values": {"root_module": {"resources": [{
	"address": "data.aws_iam_policy_document.test",
	"mode": "data",
	"type": "aws_iam_policy_document",
	"values": {"statement": statements},
}]}}}}

test_document_wildcard_action_denied_while_resources_unknown if {
	rcs := [doc_read([{"actions": ["logs:*"], "resources": null, "principals": []}], {"statement": [{"resources": true}]})]
	has_rule(deny, "MB-POL-03") with input as plan(rcs)
}

test_document_specific_actions_unknown_resources_allowed if {
	rcs := [doc_read([{"actions": ["logs:PutLogEvents"], "resources": null, "principals": []}], {"statement": [{"resources": true}]})]
	count(deny) == 0 with input as plan(rcs)
}

test_document_in_prior_state_resource_star_denied if {
	has_rule(deny, "MB-POL-03") with input as doc_in_state([{"effect": "Allow", "actions": ["s3:GetObject"], "resources": ["*"], "principals": []}])
}

test_document_get_authorization_token_on_star_allowed if {
	count(deny) == 0 with input as doc_in_state([{"effect": "Allow", "actions": ["ecr:GetAuthorizationToken"], "resources": ["*"], "principals": []}])
}

test_document_not_actions_denied if {
	has_rule(deny, "MB-POL-03") with input as doc_in_state([{"effect": "Allow", "not_actions": ["iam:*"], "resources": ["*"], "principals": []}])
}

test_key_policy_document_with_principals_ignored if {
	count(deny) == 0 with input as doc_in_state([{"effect": "Allow", "actions": ["kms:*"], "resources": ["*"], "principals": [{"type": "AWS", "identifiers": ["arn:aws:iam::111122223333:root"]}]}])
}

test_document_deny_statement_ignored if {
	count(deny) == 0 with input as doc_in_state([{"effect": "Deny", "actions": ["*"], "resources": ["*"], "principals": []}])
}

# ---------- MB-POL-09 supply chain ----------

verified_state := {"values": {"root_module": {"resources": [{
	"address": "data.external.image_signature[0]",
	"mode": "data",
	"type": "external",
	"values": {"result": {"verified": "true"}},
}]}}}

pinned := object.union(hardened, {"image": "111122223333.dkr.ecr.us-east-1.amazonaws.com/medibook/api@sha256:aaaa"})

test_verified_pinned_image_allowed if {
	count(deny) == 0 with input as {"resource_changes": [task(pinned)], "prior_state": verified_state}
}

test_image_by_tag_denied if {
	has_rule(deny, "MB-POL-09") with input as {"resource_changes": [task(object.union(pinned, {"image": "medibook/api:latest"}))], "prior_state": verified_state}
}

test_deploy_without_signature_verification_denied if {
	has_rule(deny, "MB-POL-09") with input as plan([task(pinned)])
}

test_verification_deferred_to_apply_allowed if {
	read := {"address": "data.external.image_signature[0]", "mode": "data", "type": "external", "change": {"actions": ["read"], "after": {}, "after_unknown": {}}}
	count(deny) == 0 with input as plan([task(pinned), read])
}

test_list_oidc_providers_on_star_allowed if {
	count(deny) == 0 with input as doc_in_state([{"effect": "Allow", "actions": ["iam:ListOpenIDConnectProviders"], "resources": ["*"], "principals": []}])
}

test_describe_availability_zones_on_star_allowed if {
	count(deny) == 0 with input as doc_in_state([{"effect": "Allow", "actions": ["ec2:DescribeAvailabilityZones"], "resources": ["*"], "principals": []}])
}
