/* SPDX-License-Identifier: GPL-3.0-or-later
 * Copyright 2026 125hz
 * Madeira Converter Exception: see LICENSE-EXCEPTION.md */
#include "validation.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>
int main(void)
{
    uint32_t option = 99;
    assert(sh_parse_launch_option("0", &option) && option == 0);
    assert(sh_parse_launch_option("1", &option) && option == 1);
    assert(sh_parse_launch_option("17", &option) && option == 17);
    assert(sh_parse_launch_option("2147483647", &option) && option == INT32_MAX);
    assert(!sh_parse_launch_option("2147483648", &option));
    assert(!sh_parse_launch_option("4294967295", &option));
    assert(!sh_parse_launch_option("00000000000", &option));
    assert(!sh_parse_launch_option("", &option) && !sh_parse_launch_option(NULL, &option));
    assert(!sh_parse_launch_option("-1", &option) && !sh_parse_launch_option("+1", &option));
    assert(!sh_parse_launch_option(" 1", &option) && !sh_parse_launch_option("1x", &option));
    assert(!sh_parse_launch_option("1", NULL));
    unsigned char missing[524] = {0};
    const char missing_text[] = "entry for launch option 7 not found";
    memcpy(missing + 12, missing_text, sizeof(missing_text));
    assert(sh_launch_option_missing(missing, sizeof(missing), 7));
    assert(!sh_launch_option_missing(missing, sizeof(missing), 0));
    assert(!sh_launch_option_missing(missing, 12, 7));
    assert(!sh_launch_option_missing(NULL, sizeof(missing), 7));
    memset(missing + 12, 'x', 512);
    assert(!sh_launch_option_missing(missing, sizeof(missing), 7));
    memset(missing + 12, 0, 512);
    const char pending_text[] = "configuration not yet available";
    memcpy(missing + 12, pending_text, sizeof(pending_text));
    assert(!sh_launch_option_missing(missing, sizeof(missing), 7));
    uint32_t apps[] = {17, 29, 44, 0};
    assert(sh_subscription_list_contains(apps, 3, 4, 29));
    assert(!sh_subscription_list_contains(apps, 3, 4, 30));
    assert(!sh_subscription_list_contains(NULL, 3, 4, 29));
    assert(!sh_subscription_list_contains(apps, -1, 4, 29));
    assert(!sh_subscription_list_contains(apps, 0, 4, 29));
    assert(!sh_subscription_list_contains(apps, 4, 4, 29));
    assert(!sh_subscription_list_contains(apps, INT32_MAX, 4, 29));
    assert(!sh_subscription_list_contains(apps, 3, 4, 0));
    assert(!sh_subscription_list_contains(apps, 3, 4, UINT32_MAX));
    unsigned char payload[524] = {0};
    uint64_t gameid = 29;
    int32_t error = -1, denied = 5;
    memcpy(payload, &gameid, 8);
    assert(sh_decode_launch_result(payload, sizeof(payload), gameid, &error) && error == 0);
    memcpy(payload+8, &denied, 4);
    assert(sh_decode_launch_result(payload, sizeof(payload), gameid, &error) && error == denied);
    assert(!sh_decode_launch_result(payload, sizeof(payload), gameid+1, &error));
    assert(!sh_decode_launch_result(payload, 12, gameid, &error));
    assert(!sh_decode_launch_result(payload, 528, gameid, &error));
    assert(!sh_decode_launch_result(NULL, 524, gameid, &error));
    assert(!sh_decode_launch_result(payload, 524, gameid, NULL));
    assert(SH_CONTENT_WAIT_MS == 180000);
    assert(!sh_launch_content_wait_expired(999999, 0));
    assert(!sh_launch_content_wait_expired(99, 100));
    assert(!sh_launch_content_wait_expired(180099, 100));
    assert(sh_launch_content_wait_expired(180100, 100));
    assert(sh_launch_content_wait_expired(4600000, 100));
    assert(sh_launch_error_waits_for_content(17));
    assert(sh_launch_error_waits_for_content(19));
    assert(sh_launch_error_waits_for_content(20));
    assert(!sh_launch_error_waits_for_content(0));
    assert(!sh_launch_error_waits_for_content(5));
    assert(!sh_launch_error_waits_for_content(6));
    assert(!sh_launch_error_waits_for_content(-1));
    assert(sh_launch_error_waits_for_config(22) && sh_launch_error_waits_for_config(23));
    assert(!sh_launch_error_waits_for_config(17) && !sh_launch_error_waits_for_config(24) &&
           !sh_launch_error_waits_for_config(5) && !sh_launch_error_waits_for_config(0));
    assert(sh_launch_error_waits_for_session(35) && !sh_launch_error_waits_for_session(16) &&
           !sh_launch_error_waits_for_session(22) && !sh_launch_error_waits_for_session(0));
    assert(sh_launch_retry_delay_ms(0) == 10000 && sh_launch_retry_delay_ms(1) == 20000);
    assert(sh_launch_retry_delay_ms(2) == 30000 && sh_launch_retry_delay_ms(900) == 30000);
    unsigned char job[12] = {0};
    int32_t ok = 1, busy = 10, ceg = 0;
    uint32_t app = 29;
    memcpy(job, &ok, 4); memcpy(job+4, &app, 4);
    assert(sh_decode_ceg_job(job, 8, 29, &ceg) && ceg == 1);
    assert(!sh_decode_ceg_job(job, 8, 30, &ceg));
    assert(!sh_decode_ceg_job(job, 12, 29, &ceg));
    assert(!sh_decode_ceg_job(job, 4, 29, &ceg));
    assert(!sh_decode_ceg_job(NULL, 8, 29, &ceg));
    assert(!sh_decode_ceg_job(job, 8, 29, NULL));
    assert(!sh_decode_ceg_job(job, 8, 0, &ceg));
    memcpy(job, &busy, 4);
    assert(sh_decode_ceg_reply(job, 12, 29, &ceg) && ceg == 10);
    assert(!sh_decode_ceg_reply(job, 8, 29, &ceg));
    struct sh_ceg_progress progress = {0};
    assert(sh_ceg_request_step(10, 0, &progress) == SH_CEG_RETRY);
    assert(sh_ceg_request_step(1, 0, &progress) == SH_CEG_FAIL && progress.failure == 0);
    assert(sh_ceg_request_step(2, 0, &progress) == SH_CEG_FAIL && progress.failure == 2);
    assert(sh_ceg_request_step(55, 3, &progress) == SH_CEG_FAIL && progress.failure == 55);
    assert(sh_ceg_request_step(1, UINT32_MAX, &progress) == SH_CEG_FAIL);
    assert(sh_ceg_request_step(1, SH_CEG_MAX_JOBS + 1, &progress) == SH_CEG_FAIL);
    assert(sh_ceg_request_step(1, 2, NULL) == SH_CEG_FAIL);
    assert(sh_ceg_request_step(1, 2, &progress) == SH_CEG_WAIT && progress.expected == 2);
    assert(sh_ceg_record_job(&progress, 1) == SH_CEG_WAIT);
    assert(sh_ceg_record_job(&progress, 1) == SH_CEG_DONE);
    assert(sh_ceg_record_job(&progress, 1) == SH_CEG_FAIL);
    assert(sh_ceg_request_step(1, 2, &progress) == SH_CEG_WAIT && progress.finished == 0);
    assert(sh_ceg_record_job(&progress, 3) == SH_CEG_FAIL && progress.failure == 3);
    assert(sh_ceg_request_step(1, 1, &progress) == SH_CEG_WAIT);
    assert(sh_ceg_record_job(&progress, 0) == SH_CEG_FAIL);
    struct sh_ceg_progress empty = {0};
    assert(sh_ceg_record_job(&empty, 1) == SH_CEG_FAIL && sh_ceg_record_job(NULL, 1) == SH_CEG_FAIL);
    /* ml2000: service-manager decisions. */
    assert(sh_scm_error_means_absent(1722));
    assert(!sh_scm_error_means_absent(1723) && !sh_scm_error_means_absent(5) && !sh_scm_error_means_absent(0));
    assert(sh_scm_error_retryable(1722) && sh_scm_error_retryable(1723));
    assert(!sh_scm_error_retryable(5) && !sh_scm_error_retryable(1060) && !sh_scm_error_retryable(0));
    assert(sh_scm_poll_slice_ms(0) == 0 && sh_scm_poll_slice_ms(1) == 1);
    assert(sh_scm_poll_slice_ms(SH_SCM_POLL_MS) == SH_SCM_POLL_MS && SH_SCM_POLL_MS == 250);
    assert(sh_scm_poll_slice_ms(30000) == SH_SCM_POLL_MS && sh_scm_poll_slice_ms(UINT32_MAX - 1) == SH_SCM_POLL_MS);
    assert(sh_ceg_scm_result(true, true) == 0);
    assert(sh_ceg_scm_result(true, false) == SH_CEG_SERVICE_UNREGISTERED && SH_CEG_SERVICE_UNREGISTERED == -5);
    assert(sh_ceg_scm_result(false, true) == SH_CEG_SCM_UNAVAILABLE && SH_CEG_SCM_UNAVAILABLE == -4);
    assert(sh_ceg_scm_result(false, false) == SH_CEG_SCM_UNAVAILABLE);
    assert(sh_remaining_ms(1000, 1000, 30000) == 30000);
    assert(sh_remaining_ms(30999, 1000, 30000) == 1);
    assert(sh_remaining_ms(31000, 1000, 30000) == 0 && sh_remaining_ms(UINT64_MAX, 0, 30000) == 0);
    assert(sh_remaining_ms(500, 1000, 30000) == 30000);
    assert(sh_remaining_ms(0, 0, UINT64_MAX) == UINT32_MAX - 1);
    assert(sh_service_stop_outcome(false, false, false, false) == SH_SERVICE_NOT_RUNNING);
    assert(sh_service_stop_outcome(false, true, true, true) == SH_SERVICE_NOT_RUNNING);
    assert(sh_service_stop_outcome(true, true, true, false) == SH_SERVICE_STOPPED);
    assert(sh_service_stop_outcome(true, true, false, true) == SH_SERVICE_ENDED_AFTER_BOUND);
    assert(sh_service_stop_outcome(true, false, false, true) == SH_SERVICE_ENDED_AFTER_BOUND);
    assert(sh_service_stop_outcome(true, true, false, false) == SH_SERVICE_STOP_FAILED);
    assert(sh_service_stop_outcome(true, false, true, false) == SH_SERVICE_STOP_FAILED);
    /* ml2000: Valve's own service installer decision and report value. */
    assert(sh_should_install_service(false, true, true));
    assert(!sh_should_install_service(false, true, false));
    assert(!sh_should_install_service(true, false, true) && !sh_should_install_service(true, true, true));
    assert(!sh_should_install_service(false, false, true));
    assert(sh_service_install_report(false, true, 0) == SH_SERVICE_INSTALL_MISSING && SH_SERVICE_INSTALL_MISSING == -2);
    assert(sh_service_install_report(true, false, 0) == SH_SERVICE_INSTALL_TIMEOUT && SH_SERVICE_INSTALL_TIMEOUT == -1);
    assert(sh_service_install_report(true, true, 0) == 0 && sh_service_install_report(true, true, 5) == 5);
    assert(sh_service_install_report(true, true, 0xC0000005u) == (int32_t)0xC0000005u);
    /* ml2014: --start-services for the one-time-install batch. */
    assert(sh_install_scm_should_spawn(true, 1722));
    assert(!sh_install_scm_should_spawn(false, 1722));
    assert(!sh_install_scm_should_spawn(true, 0) && !sh_install_scm_should_spawn(true, 1723) &&
           !sh_install_scm_should_spawn(true, 5));
    assert(sh_install_scm_outcome(false, 1722, false, false) == SH_INSTALL_SCM_OFF);
    assert(sh_install_scm_outcome(false, 0, false, true) == SH_INSTALL_SCM_OFF);
    assert(sh_install_scm_outcome(true, 0, false, true) == SH_INSTALL_SCM_ALREADY);
    assert(sh_install_scm_outcome(true, 1722, true, true) == SH_INSTALL_SCM_STARTED);
    assert(sh_install_scm_outcome(true, 1722, false, true) == SH_INSTALL_SCM_ALREADY);
    assert(sh_install_scm_outcome(true, 1722, true, false) == SH_INSTALL_SCM_FAILED);
    assert(sh_install_scm_outcome(true, 5, false, false) == SH_INSTALL_SCM_FAILED);
    assert(!strcmp(sh_install_scm_word(SH_INSTALL_SCM_STARTED), "started"));
    assert(!strcmp(sh_install_scm_word(SH_INSTALL_SCM_ALREADY), "already"));
    assert(!strcmp(sh_install_scm_word(SH_INSTALL_SCM_OFF), "off"));
    assert(!strcmp(sh_install_scm_word(SH_INSTALL_SCM_FAILED), "failed"));
    assert(!strcmp(sh_install_scm_word(7), "failed"));
    puts("steam-host: launch-option, entitlement-list, launch-result, content-wait, config-wait, session-wait, CEG, service-manager "
         "and install-service-manager validation cases passed");
}
