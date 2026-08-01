# Plan: Comprehensive Error Handling & Failure Mode Analysis

**CRITICAL ISSUE FOUND**: launch.ps1 requires R >= 4.5, but installer downloads R 4.4.2. This mismatch will cause installation failures.

## Discovery Summary

Analyzed 7 critical failure points across installation and runtime phases.

### 🔴 CRITICAL BUGS FOUND:

1. **R Version Requirement Mismatch** 
   - Installer: Requires R >= 4.4, downloads R 4.4.2
   - launch.ps1: Requires R >= 4.5, rejects R 4.4.x
   - **Impact**: App installs but won't launch ("R 4.5 or higher is required")

### ⚠️ MISSING ERROR HANDLING:

2. **PowerShell Execution Policy Blocks** - launch.ps1 may fail if ExecutionPolicy = Restricted
3. **Package Installation Silent Failures** - Network timeouts have no retry logic
4. **Config File Corruption** - Malformed JSON crashes app with no recovery
5. **API Key Validation** - No validation until first chat attempt
6. **LLM Connectivity Failures** - Network errors during chat streaming have no retry

## Failure Scenarios by Phase

### Phase 1: Installer Execution

| Scenario | Current Handling | Risk | Fix Needed |
|----------|-----------------|------|------------|
| **R >= 4.4 found, < 4.5** | ✅ Installer accepts | 🔴 **launch.ps1 rejects** | Fix version check |
| R not in registry | ✅ File system scan | ✅ Good | None |
| Download fails (no internet) | ✅ Error dialog with manual URL | ✅ Good | None |
| R installer fails | ⚠️ Shows exit code | ⚠️ Unclear to user | Add troubleshooting |
| Insufficient permissions | ❌ Silent failure | 🔴 Critical | Detect admin requirement |

### Phase 2: First Launch (launch.ps1)

| Scenario | Current Handling | Risk | Fix Needed |
|----------|-----------------|------|------------|
| **R 4.4.x installed** | 🔴 **Rejects with error** | 🔴 **Critical** | **Change to >= 4.4** |
| ExecutionPolicy blocked | ❌ PowerShell error | 🔴 Critical | Detect & guide user |
| Port 7475 in use | ✅ Kills stale Rscript | ✅ Good | None |
| R not found | ✅ Error dialog with URL | ✅ Good | None |

### Phase 3: Package Installation

| Scenario | Current Handling | Risk | Fix Needed |
|----------|-----------------|------|------------|
| Binary unavailable (R 4.5.1) | ✅ Falls back to source | ✅ Good | None |
| Source compile fails (no Rtools) | ✅ Shows Rtools URL | ✅ Good | None |
| Network timeout | ⚠️ Fails entire batch | 🟡 Moderate | Add retry logic |
| Disk full | ❌ Cryptic error | 🟡 Moderate | Check free space |

### Phase 4: App Initialization (global.R)

| Scenario | Current Handling | Risk | Fix Needed |
|----------|-----------------|------|------------|
| Package load failure | ✅ Stops with clear message | ✅ Good | None |
| Config JSON corrupted | ⚠️ Returns NULL, uses defaults | ✅ Good | None |
| github_models in old config | ✅ Migrates to openai | ✅ Good | None |

### Phase 5: Runtime Execution

| Scenario | Current Handling | Risk | Fix Needed |
|----------|-----------------|------|------------|
| Invalid API key | ❌ LLM error on first chat | 🟡 Moderate | Validate on save |
| Network loss during chat | ❌ Stream stops | 🟡 Moderate | Add retry/timeout |
| LLM returns invalid code | ✅ Shows error, asks to retry | ✅ Good | None |

## Implementation Steps

### 1. Fix Critical R Version Mismatch (IMMEDIATE - BLOCKING DEPLOYMENT)
   - Update [launch.ps1](launch.ps1#L102-L106): Change `4.5` → `4.4` in version check
   - Update error message to match installer requirement
   - **Blocks**: All deployments where R 4.4.2 was auto-installed

### 2. Add PowerShell ExecutionPolicy Detection (HIGH PRIORITY)
   - Check `Get-ExecutionPolicy` before running launch.ps1
   - Show bypass instructions in error dialog if Restricted
   - Fallback: Suggest start.bat (if it bypasses policy)

### 3. Add Package Installation Resilience (MEDIUM PRIORITY)
   - Retry logic for network timeouts (3 attempts with backoff)
   - Disk space check before installation (require 500MB free)
   - Better CRAN mirror cycling (try all 3 before failing)

### 4. Add API Key Validation (MEDIUM PRIORITY)
   - Test connectivity when saving API key (simple ping to provider)
   - Show validation status in UI (✓ Valid / ✗ Invalid / ⚠️ Not tested)
   - Cache validation for 24h to avoid repeated checks

### 5. Improve Runtime Error Messages (LOW PRIORITY)
   - Data file errors: "Could not read file X. Ensure it's a valid CSV/XLSX/RDS"
   - Network errors: "Connection lost. Retrying..."
   - LLM errors: Show provider-specific troubleshooting links

## Verification Steps

After implementing fixes, test these scenarios:

1. **R Version Compatibility**
   - Install R 4.4.2 via installer → App should launch without errors
   - Install R 4.5.1 manually → App should accept it
   - Install R 4.3.3 → Installer should prompt for upgrade

2. **Package Installation**
   - Fresh R 4.4.2 → Binaries install in < 60 seconds
   - Fresh R 4.5.1 + Rtools → Source compile succeeds
   - Fresh R 4.5.1 no Rtools → Shows Rtools URL and exits
   - Simulate network loss → Retries 3x, then fails with clear message

3. **PowerShell Execution**
   - Set ExecutionPolicy to Restricted → Shows bypass instructions
   - Normal execution → Launches successfully

4. **Config Migration**
   - Load old github_models config → Auto-migrates to openai
   - Corrupted JSON config → Uses defaults, logs warning
   - Empty config → Shows settings panel on first launch

## Relevant Files

**Critical fixes needed:**
- [launch.ps1](launch.ps1#L102-L106) - R version check
- [launch.ps1](launch.ps1#L1-L30) - ExecutionPolicy detection (add)
- [launch.ps1](launch.ps1#L148-L175) - Package installation retry logic (enhance)

**Already correct:**
- [ggplot Voice Copilot Conv.iss](ggplot%20Voice%20Copilot%20Conv.iss#L6) - R 4.4.2 download
- [ggplot Voice Copilot Conv.iss](ggplot%20Voice%20Copilot%20Conv.iss#L254) - R >= 4.4 requirement
- [global.R](global.R#L47-L82) - Config loading with migration
- [global.R](global.R#L11-L32) - Package loading with clear errors

## Decisions

- **R 4.4.2 as standard**: Balances stability (CRAN binaries) with compatibility (accepts 4.5.1+)
- **Graceful degradation**: Prefer helpful errors over silent failures
- **Retry logic**: 3 attempts for network operations with exponential backoff
- **No bundled packages**: Keep installer lightweight, rely on CRAN + source fallback
- **ExecutionPolicy**: Detect and guide, don't auto-bypass (security)

## Further Considerations

1. **Should we detect admin rights before R installation?**
   - Option A: Pre-check and warn user (better UX)
   - Option B: Let R installer handle it (current behavior)
   - **Recommendation**: Option A for next iteration

2. **Should we validate API keys on save?**
   - Option A: Test connectivity immediately (fails fast, better UX)
   - Option B: Validate only when chat initializes (current behavior, faster save)
   - **Recommendation**: Option A - implement with timeout

3. **Network resilience level?**
   - Option A: Aggressive retries (up to 5 attempts, 60s total)
   - Option B: Conservative retries (3 attempts, 30s total)
   - **Recommendation**: Option B - fail reasonably fast
