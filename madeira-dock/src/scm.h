/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md */
#ifndef MADEIRA_STEAM_HOST_SCM_H
#define MADEIRA_STEAM_HOST_SCM_H
#include <windows.h>
#include "probe.h"
/* ml2000: make Wine's service manager reachable for Valve's client and check
 * (read-only) that Valve's own client service is registered. If it is not,
 * run Valve's own bin\SteamService.exe /install from the folder of the loaded
 * genuine client (as Valve's client does), then check again. Returns 0 or the
 * ceg-result failure code (-4 unreachable, -5 not registered). Dock itself
 * never writes service registration or starts a service.
 */
int32_t sh_ceg_scm_prepare(const struct sh_observer *o, HMODULE client);
/* Host exit: only if this host started the service manager, stop Valve's
 * client service (bounded) and end that service manager. Otherwise no-op.
 */
void sh_ceg_scm_release(const struct sh_observer *o);
/* ml2014: `dockhost.exe --start-services` (Madeira's one-time-install batch):
 * make Wine's service manager reachable, starting services.exe only when none
 * answers, and leave it running for the session. Returns enum sh_install_scm
 * (validation.h). MADEIRA_DOCK_INSTALL_SCM=0: no-op (off).
 */
int32_t sh_install_scm_start(const struct sh_observer *o);
#endif
