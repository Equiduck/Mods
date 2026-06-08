name = "Trade Inn Auto Fill"
description = "Adds an 'Auto Fill' button to the Trade Inn that auto-selects 9 legal items of the same rarity. Config: only use duplicates."
author = "Equiduck"
version = "1.0.0"

dst_compatible = true
all_clients_require_mod = false
client_only_mod = true

api_version = 10
icon_atlas = "modicon.xml"
icon = "modicon.tex"

configuration_options =
{
    {
        name = "DUPES_ONLY",
        label = "Use Duplicates Only",
        options =
        {
            {description = "On (default)", data = true},
            {description = "Off",          data = false},
        },
        default = true,
    },
    {
        name = "RELAX_TO_FILL",
        label = "Relax to Fill",
        hover = "If not enough dupes found, allow using singles to complete 9 slots.",
        options =
        {
            {description = "On (default)", data = true},
            {description = "Off",          data = false},
        },
        default = true,
    },
    
}

