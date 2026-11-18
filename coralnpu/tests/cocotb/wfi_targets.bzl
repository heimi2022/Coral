"""Macro to generate wfi_slot targets for template_rule."""

def get_wfi_slot_targets():
    """Returns a dictionary of wfi_slot targets for template_rule."""
    targets = {}
    for slot in range(4):
        # Standard
        targets["wfi_slot_%d" % slot] = {
            "srcs": ["wfi_slot_%d.c" % slot],
        }
    return targets
