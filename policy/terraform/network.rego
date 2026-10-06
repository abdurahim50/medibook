# MB-POL-01: no ingress from the whole internet, except web ports.
# NIST SP 800-53: SC-7 (boundary protection).
package main

open_cidrs := {"0.0.0.0/0", "::/0"}

web_ports := {80, 443}

web_port_range(from, to) if {
	from == to
	from in web_ports
}

# Standalone rules (the style used in infra/network.tf).
deny contains msg if {
	some rc in resources
	rc.type == "aws_vpc_security_group_ingress_rule"
	a := rc.change.after
	some field in ["cidr_ipv4", "cidr_ipv6"]
	a[field] in open_cidrs
	not web_port_range(a.from_port, a.to_port)
	msg := sprintf("MB-POL-01 %s: ingress from %s on ports %v-%v (protocol %v); only 80 and 443 may be open to the internet", [rc.address, a[field], a.from_port, a.to_port, a.ip_protocol])
}

# Legacy aws_security_group_rule resources.
deny contains msg if {
	some rc in resources
	rc.type == "aws_security_group_rule"
	a := rc.change.after
	a.type == "ingress"
	some cidr in array.concat(object.get(a, "cidr_blocks", []), object.get(a, "ipv6_cidr_blocks", []))
	cidr in open_cidrs
	not web_port_range(a.from_port, a.to_port)
	msg := sprintf("MB-POL-01 %s: ingress from %s on ports %v-%v; only 80 and 443 may be open to the internet", [rc.address, cidr, a.from_port, a.to_port])
}

# Inline ingress blocks inside aws_security_group.
deny contains msg if {
	some rc in resources
	rc.type == "aws_security_group"
	some rule in rc.change.after.ingress
	some cidr in array.concat(object.get(rule, "cidr_blocks", []), object.get(rule, "ipv6_cidr_blocks", []))
	cidr in open_cidrs
	not web_port_range(rule.from_port, rule.to_port)
	msg := sprintf("MB-POL-01 %s: inline ingress from %s on ports %v-%v; only 80 and 443 may be open to the internet", [rc.address, cidr, rule.from_port, rule.to_port])
}
