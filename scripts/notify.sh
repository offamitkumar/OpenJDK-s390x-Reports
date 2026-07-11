#!/usr/bin/env bash
# =============================================================================
# notify.sh — Send a CI run notification email
#
# Sourced (not executed directly) by run_daily.sh, jdk.sh, and pr_test.sh.
# Exposes a single public function:
#
#   ci_notify  <run_kind> <subject_suffix> <summary_file> <overall_status> \
#              <commit_info_file> \
#              [<stream_label>:<src_dir>:<level>:<build_status> ...]
#
# Arguments:
#   run_kind          — "daily" | "manual" | "pr"
#   subject_suffix    — short description, e.g. "head/fastdebug" or "PR #31868"
#   summary_file      — path to run-summary.txt (opening section of the email)
#   overall_status    — "PASS" | "FAIL" | anything else
#   commit_info_file  — path to a file containing commit information
#                       (commit-info.txt or pr-info.txt).  For daily runs with
#                       multiple streams, pass the path of a combined file or
#                       the first stream's file.  Pass "" to omit this section.
#                       The file is included verbatim so the reader can copy
#                       the bisect command directly from the email.
#   stream_label:src_dir:level:build_status
#       Colon-joined quad describing one build × level combination.
#       build_status must be one of:
#         BUILD_FAILED   — configure/make failed; build.log shown; no test section
#         TEST_PASSED    — all tier1 tests passed; newfailures + other_errors shown
#         TEST_FAILED    — tier1 ran with failures; newfailures + other_errors shown
#         (anything else treated as TEST_PASSED for display purposes)
#
#       src_dir / level usage:
#         Normal (level = fastdebug | release | slowdebug):
#           test-results/ at <src_dir>/build/linux-s390x-server-<level>/test-results/
#         Report  (level = __report__):
#           Used by pr_test.sh — flat copies in <src_dir>/newfailures.txt etc.
#
# Required environment (set via config.sh):
#   CI_NOTIFY_EMAIL        space-separated recipient list; empty = no mail
#   CI_NOTIFY_ON_SUCCESS   "true" | "false"   (default: true)
#   CI_NOTIFY_ON_FAILURE   "true" | "false"   (default: true)
#   CI_NOTIFY_FROM         From address
#
# Mailer: `mail` (GNU Mailutils / bsd-mailx), falls back to `sendmail -t`.
#         Failure to send never aborts the CI run (always returns 0).
# =============================================================================

# Guard against double-sourcing
[[ -n "${_CI_NOTIFY_SH_LOADED:-}" ]] && return 0
_CI_NOTIFY_SH_LOADED=1

_notify_ts()   { date -u '+%H:%M:%S'; }
_notify_info() { echo "$(_notify_ts) [notify] $*"; }
_notify_warn() { echo "$(_notify_ts) [notify] WARN: $*" >&2; }

# ---------------------------------------------------------------------------
# _notify_check_mailer — sets _NOTIFY_MAILER to "mail", "sendmail", or ""
# ---------------------------------------------------------------------------
_notify_check_mailer() {
    if command -v mail &>/dev/null; then
        _NOTIFY_MAILER="mail"
    elif command -v sendmail &>/dev/null; then
        _NOTIFY_MAILER="sendmail"
    else
        _NOTIFY_MAILER=""
    fi
}

# ---------------------------------------------------------------------------
# _notify_build_section  <stream_label> <src_dir> <level> <build_status>
#
# Emits one section of the email body for a single stream × level combination.
#
# If build_status == BUILD_FAILED:
#   Prints BUILD FAILED message + full build.log content. No test sections.
#
# Otherwise (tests ran):
#   Prints newfailures.txt and other_errors.txt content.
# ---------------------------------------------------------------------------
_notify_build_section() {
    local stream_label="$1"
    local src_dir="$2"
    local level="$3"
    local build_status="$4"

    # Resolve file paths
    local nf_files=() oe_files=()
    if [[ "${level}" == "__report__" ]]; then
        # pr_test.sh: flat copies already in the report output dir
        nf_files=("${src_dir}/newfailures.txt")
        oe_files=("${src_dir}/other_errors.txt")
    else
        local results_dir="${src_dir}/build/linux-s390x-server-${level}/test-results"
        mapfile -t nf_files < <(find "${results_dir}" \
            -name "newfailures.txt" 2>/dev/null | sort)
        mapfile -t oe_files < <(find "${results_dir}" \
            -name "other_errors.txt" 2>/dev/null | sort)
    fi

    # Section header always shows stream/level so it's unambiguous
    local display_level="${level}"
    [[ "${level}" == "__report__" ]] && display_level="fastdebug"

    echo ""
    echo "###################################################################"
    echo "  ${stream_label} / ${display_level}  [${build_status}]"
    echo "###################################################################"

    if [[ "${build_status}" == BUILD_FAILED* ]]; then
        local build_log
        if [[ "${level}" == "__report__" ]]; then
            build_log="${src_dir}/build.log"
        else
            build_log="${src_dir}/build/linux-s390x-server-${level}/build.log"
        fi
        echo ""
        echo "  BUILD FAILED — configure or make images did not complete."
        echo "  Tier1 tests did not run."
        echo ""
        echo "--- build.log ---"
        echo "    ${build_log}"
        echo ""
        if [[ -f "${build_log}" ]]; then
            cat "${build_log}"
        else
            echo "(build.log not found at ${build_log})"
        fi
        echo ""
        return
    fi

    # Tests ran — show newfailures and other_errors
    echo ""
    echo "--- newfailures.txt ---"
    if [[ ${#nf_files[@]} -gt 0 && -f "${nf_files[0]}" ]]; then
        cat "${nf_files[@]}" 2>/dev/null
    else
        echo "(none)"
    fi

    echo ""
    echo "--- other_errors.txt ---"
    if [[ ${#oe_files[@]} -gt 0 && -f "${oe_files[0]}" ]]; then
        cat "${oe_files[@]}" 2>/dev/null
    else
        echo "(none)"
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# _notify_send  <subject> <body> <recipients...>
# ---------------------------------------------------------------------------
_notify_send() {
    local subject="$1"
    local body="$2"
    shift 2
    local recipients=("$@")

    _notify_check_mailer

    if [[ -z "${_NOTIFY_MAILER}" ]]; then
        _notify_warn "No mailer found (tried: mail, sendmail)."
        _notify_warn "Install mailutils (Debian/Ubuntu) or mailx (RHEL/Fedora)."
        _notify_warn "Email not sent. Subject would have been: ${subject}"
        return 0
    fi

    local addr
    for addr in "${recipients[@]}"; do
        local mail_exit=0
        case "${_NOTIFY_MAILER}" in
            mail)
                # From header: GNU Mailutils uses -a, BSD mail uses -r
                local _from_flag=()
                if mail --help 2>&1 | grep -q -- '-a '; then
                    _from_flag=(-a "From: ${CI_NOTIFY_FROM}")
                else
                    _from_flag=(-r "${CI_NOTIFY_FROM}")
                fi
                printf '%s' "${body}" \
                    | mail -s "${subject}" "${_from_flag[@]}" "${addr}" \
                    || mail_exit=$?
                ;;
            sendmail)
                {
                    echo "From: ${CI_NOTIFY_FROM}"
                    echo "To: ${addr}"
                    echo "Subject: ${subject}"
                    echo "Content-Type: text/plain; charset=utf-8"
                    echo ""
                    printf '%s' "${body}"
                } | sendmail -t || mail_exit=$?
                ;;
        esac

        if [[ ${mail_exit} -ne 0 ]]; then
            _notify_warn "Mailer exited ${mail_exit} for ${addr} — email may not have been delivered."
        else
            _notify_info "Email sent to ${addr}"
        fi
    done
}

# ---------------------------------------------------------------------------
# ci_notify  <run_kind> <subject_suffix> <summary_file> <overall_status> \
#            [<src_dir>:<level>:<build_status> ...]
# ---------------------------------------------------------------------------
ci_notify() {
    local run_kind="$1"
    local subject_suffix="$2"
    local summary_file="$3"
    local overall_status="$4"
    local commit_info_file="$5"   # path to commit-info.txt / pr-info.txt, or ""
    shift 5
    local triples=("$@")   # stream_label:src_dir:level:build_status

    # ---- Guards ----------------------------------------------------------
    if [[ -z "${CI_NOTIFY_EMAIL:-}" ]]; then
        _notify_info "CI_NOTIFY_EMAIL not set — skipping notification."
        return 0
    fi
    case "${overall_status}" in
        PASS)
            if [[ "${CI_NOTIFY_ON_SUCCESS:-true}" != "true" ]]; then
                _notify_info "CI_NOTIFY_ON_SUCCESS=false — skipping."
                return 0
            fi ;;
        FAIL)
            if [[ "${CI_NOTIFY_ON_FAILURE:-true}" != "true" ]]; then
                _notify_info "CI_NOTIFY_ON_FAILURE=false — skipping."
                return 0
            fi ;;
    esac

    # ---- Subject ---------------------------------------------------------
    local icon
    case "${overall_status}" in
        PASS) icon="[PASS]" ;; FAIL) icon="[FAIL]" ;; *) icon="[INFO]" ;;
    esac
    local kind_label
    case "${run_kind}" in
        daily)  kind_label="Daily CI"    ;;
        manual) kind_label="Manual run"  ;;
        pr)     kind_label="PR test"     ;;
        *)      kind_label="${run_kind}" ;;
    esac
    local subject="${icon} [s390x CI] ${kind_label}: ${subject_suffix}"

    # ---- Body ------------------------------------------------------------
    local body=""

    # Opening: run-summary.txt
    if [[ -f "${summary_file}" ]]; then
        body+="$(cat "${summary_file}")"
    else
        body+="(run-summary.txt not found: ${summary_file})"
    fi

    # Commit information — before/after commits + bisect command
    if [[ -n "${commit_info_file}" && -f "${commit_info_file}" ]]; then
        body+="

###################################################################
  Commit Information
###################################################################
$(cat "${commit_info_file}")"
    fi

    # Per-build sections
    for triple in "${triples[@]}"; do
        # Format: stream_label:src_dir:level:build_status
        # src_dir may itself contain colons (e.g. on unusual paths) so split
        # from the right: last = build_status, second-to-last = level,
        # third-to-last = last segment of src_dir... but stream_label is first.
        # Strategy: strip stream_label (up to first ':'), then split remainder
        # from the right for build_status and level.
        local stream_label="${triple%%:*}"
        local rest="${triple#*:}"
        local build_status="${rest##*:}"
        local rest2="${rest%:*}"
        local level="${rest2##*:}"
        local src_dir="${rest2%:*}"
        body+="$(_notify_build_section "${stream_label}" "${src_dir}" "${level}" "${build_status}")"
    done

    # Footer
    body+="
--
OpenJDK s390x CI  |  Host: $(hostname)  |  $(date -u '+%Y-%m-%d %H:%M UTC')
"

    # ---- Recipients ------------------------------------------------------
    local -a recipients=()
    local raw="${CI_NOTIFY_EMAIL//,/ }"
    read -r -a recipients <<< "${raw}"

    _notify_info "Sending notification: ${subject}"
    _notify_info "  To     : ${recipients[*]}"
    _notify_info "  Status : ${overall_status}"

    _notify_send "${subject}" "${body}" "${recipients[@]}"
}
