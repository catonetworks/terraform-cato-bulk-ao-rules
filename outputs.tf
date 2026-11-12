output "deployment_summary" {
  description = "Counts of managed Always-On objects."
  value = {
    sections = length(cato_always_on_section.sections)
    rules    = length(cato_always_on_rule.rules)
  }
}

output "section_ids" {
  description = "Map of section name to section id."
  value       = { for name, s in cato_always_on_section.sections : name => s.id }
}

output "rule_ids" {
  description = "Map of rule name to rule id."
  value       = { for name, r in cato_always_on_rule.rules : name => r.rule.id }
}

# Ordering rows the move resource cannot address (section_name "" - rules at
# the policy root). Their order is creation order. Informational only.
output "unordered_rules" {
  description = "rules_in_sections rows excluded from cato_always_on_rule_bulk (no managed section to order within)."
  value       = local.unordered_rules_data
}
