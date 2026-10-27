/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md
 * ml1860: exact, independently inspected Valve builds. Never select an ABI
 * from a date/version or interface presence alone. See docs/CLIENT_LAYOUTS.md.
 */
#include "client_layout.h"
#include <string.h>
static const struct dock_client_layout layouts[] = {
    {
        "caba4826aa3501039d095aee1843a6bfb270fb43a3ab4455b2d6733223579fee", 202609,
        0x972ff0, 0x970ba0, 0x970d30,
        0x8412f0, 0x736110, 0x729a20, 0x72ee00, 0x859860, 0x869f80,
        0x7324e0, 0x735670, 0x792860, 0x83f0f0, 0x758760,
        0x84e8b0,
        0x77e460, 0x73cbb0, 0x8415d0
    },
    {
        "71b391fe9f3e2006cbc81a5c75eef3eb4186012deabfdb2c8b7e8d4850ecf640", 202601,
        0x9450e0, 0x942d40, 0x942ed0,
        0x81d7f0, 0x719dc0, 0x70d170, 0x712af0, 0x8352d0, 0x8459b0,
        0x716040, 0x719320, 0x775440, 0x81b840, 0x73b930,
        0x82a8c0,
        0x7612c0, 0x720330, 0x81dad0
    },
    {
        /* MABD local: Valve's 64-bit client 1792618285 (steam_client_win64,
         * bins_win64), October 2026. Same slots as 202601; every pinned RVA
         * re-read by RTTI and method name, see docs/CLIENT_LAYOUTS.md. */
        "253e0a11a4415b38c78a42f7bdd6ecc426455f06c1ba6453a48090df3142dbbc", 202610,
        0x983670, 0x981220, 0x9813b0,
        0x853860, 0x747480, 0x73a950, 0x73ffa0, 0x86bf80, 0x87c6e0,
        0x7436c0, 0x7469e0, 0x7a3db0, 0x8514e0, 0x769e70,
        0x860cb0,
        0x78f9b0, 0x74e290, 0x853b40
    }
};
const struct dock_client_layout *dock_client_layout(const char *sha256)
{
    if (!sha256) return NULL;
    for (unsigned i = 0; i < sizeof(layouts) / sizeof(layouts[0]); ++i)
        if (!strcmp(sha256, layouts[i].sha256)) return &layouts[i];
    return NULL;
}
bool dock_method_is(uintptr_t module, void *object, unsigned slot, uintptr_t rva)
{
    return object && *(void ***)object && module && rva &&
        (*(void ***)object)[slot] == (void *)(module + rva);
}
