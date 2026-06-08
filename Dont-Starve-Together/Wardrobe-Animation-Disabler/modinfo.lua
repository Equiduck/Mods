name = "Wardrobe Animation Disabler"
description = "Disables animations when changing clothes in the Wardrobe Screen. My first DST mod"
author = "Equiduck"
version = "1.3"
-- The forum thread URL for your mod (optional)
forumthread = ""
-- This mod is for Don't Starve Together
dst_compatible = true
-- Mark the mod as client-only
client_only_mod = true
-- Not necessary for client-only mods
server_only_mod = false
all_clients_require_mod = false

configuration_options =
{
    {
        name  = "disable_item_collection_anims",
        label = "Disable Item Collection Animations",
        options =
        {
            { description = "Disabled", data = false }, -- default: play the usual emotes
            { description = "Enabled",  data = true  }, -- when ON: idle-only in Item Collection
        },
        default = false,
    },
}



