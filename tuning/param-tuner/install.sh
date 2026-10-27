#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# perf-params-tuner-agent Skill Installer
#
# Usage:
#   ./install.sh                         # Install to ./.opencode/skills/ (default)
#   ./install.sh --global                # Install to ~/.config/opencode/skills/
#   ./install.sh --project               # Install to ./.opencode/skills/
#   ./install.sh --project <path>        # Install to <path>/.opencode/skills/
#   ./install.sh --devkitai              # Install to <devkitai_install_dir>/skills/
#
# When installing to OpenCode (project/global), the script also
# builds and deploys the TUI dashboard plugin via build.mjs --deploy.
# ============================================================

SKILL_NAME="perf-params-tuner-agent"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="$SCRIPT_DIR/perf-params-tuner-agent"  # The skill directory

# stop-devkit 服务器插件（ESC 停止任务时同步终止 devkit 进程）
STOP_DEVKIT_SRC="$SCRIPT_DIR/opencode-plugins/stop-devkit/stop-devkit-on-abort.js"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

print_info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
print_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
print_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
print_error() { echo -e "${RED}[ERROR]${NC} $*"; }

# --- Parse arguments ---
MODE="project"
PROJECT_PATH=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --global|-g)
            MODE="global"
            shift
            ;;
        --project|-p)
            MODE="project"
            shift
            # Optional path argument (must not start with --)
            if [[ $# -gt 0 && ! "$1" =~ ^-- ]]; then
                PROJECT_PATH="$1"
                PROJECT_PATH="$(cd "$PROJECT_PATH" 2>/dev/null && pwd || echo "$PROJECT_PATH")"
                shift
            fi
            ;;
        --devkitai|-d)
            MODE="devkitai"
            shift
            ;;
        --help|-h)
            echo "Usage: ./install.sh [--global | --project [path] | --devkitai]"
            echo ""
            echo "Options:"
            echo "  --global, -g            Install to ~/.config/opencode/skills/ (all projects)"
            echo "  --project, -p [path]   Install to [path]/.opencode/skills/ (default: current dir)"
            echo "  --devkitai, -d          Install to <devkitai_install_dir>/skills/"
            echo "  --help, -h              Show this help message"
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            echo "Run './install.sh --help' for usage."
            exit 1
            ;;
    esac
done

# --- Determine target directory ---
if [[ "$MODE" == "global" ]]; then
    TARGET_BASE="${HOME}/.config/opencode/skills"
    SCOPE="global (OpenCode)"
elif [[ "$MODE" == "devkitai" ]]; then
    SCOPE="devkitai"
    # Find devkitai command in PATH
    DEVKITAI_BIN="$(command -v devkitai 2>/dev/null || true)"
    if [[ -z "$DEVKITAI_BIN" ]]; then
        print_error "devkitai command not found in PATH."
        print_error "Please ensure devkitai is installed and in your PATH."
        exit 1
    fi
    # Resolve symlinks to get the real binary path
    DEVKITAI_BIN="$(readlink -f "$DEVKITAI_BIN" 2>/dev/null || echo "$DEVKITAI_BIN")"
    DEVKITAI_DIR="$(dirname "$DEVKITAI_BIN")"
    # If binary is in a 'bin' directory, go up one level to find install root
    if [[ "$(basename "$DEVKITAI_DIR")" == "bin" ]]; then
        DEVKITAI_ROOT="$(dirname "$DEVKITAI_DIR")"
    else
        DEVKITAI_ROOT="$DEVKITAI_DIR"
    fi
    TARGET_BASE="${DEVKITAI_ROOT}/skills"
    print_info "Found devkitai:  $DEVKITAI_BIN"
    print_info "Install root:    $DEVKITAI_ROOT"
else
    # project mode: use specified path or current directory
    if [[ -n "$PROJECT_PATH" ]]; then
        if [[ ! -d "$PROJECT_PATH" ]]; then
            print_error "Project path does not exist: $PROJECT_PATH"
            exit 1
        fi
        TARGET_BASE="${PROJECT_PATH}/.opencode/skills"
        SCOPE="project (OpenCode): $PROJECT_PATH"
    else
        TARGET_BASE=".opencode/skills"
        SCOPE="project (OpenCode)"
    fi
fi

TARGET_DIR="${TARGET_BASE}/${SKILL_NAME}"

# --- Pre-flight checks ---
if [[ ! -f "$SRC_DIR/SKILL.md" ]]; then
    print_error "SKILL.md not found in $SRC_DIR"
    print_error "Please ensure perf-params-tuner-agent/ is in the same directory as this script."
    exit 1
fi

print_info "Skill name:    $SKILL_NAME"
print_info "Source:        $SRC_DIR"
print_info "Scope:         $SCOPE"
print_info "Target:        $TARGET_DIR"
echo ""

# --- Create target base directory ---
mkdir -p "$TARGET_BASE"
print_ok "Created base directory: $TARGET_BASE"

# --- Remove existing installation if present ---
if [[ -d "$TARGET_DIR" ]]; then
    print_warn "Existing installation found at $TARGET_DIR"
    read -r -p "Overwrite? (y/N): " CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        rm -rf "$TARGET_DIR"
        print_ok "Removed previous installation."
    else
        print_error "Installation cancelled by user."
        exit 1
    fi
fi

# --- Copy skill directory ---
mkdir -p "$TARGET_DIR"
cp -r "$SRC_DIR"/* "$TARGET_DIR/"

# Remove install.sh from the copied skill (not needed in target)
if [[ -f "$TARGET_DIR/install.sh" ]]; then
    rm -f "$TARGET_DIR/install.sh"
fi

print_ok "Copied skill files to $TARGET_DIR"

# --- Verify installation ---
VERIFY_OK=true

if [[ ! -f "$TARGET_DIR/SKILL.md" ]]; then
    print_error "Verification failed: SKILL.md missing in target."
    VERIFY_OK=false
fi

# Verify sub-skills
for SUB in auto-tune params-design report-summary task-design param-apply; do
    if [[ ! -f "$TARGET_DIR/$SUB/SKILL.md" ]]; then
        print_error "Verification failed: $SUB/SKILL.md missing."
        VERIFY_OK=false
    fi
done

if [[ "$VERIFY_OK" == true ]]; then
    print_ok "Installation verified successfully."
else
    print_error "Installation completed but verification found issues."
    exit 1
fi

# --- Build and deploy TUI dashboard plugin (OpenCode modes only) ---
if [[ "$MODE" != "devkitai" ]]; then
    PLUGIN_DIR="$SCRIPT_DIR/opencode-plugins/kp-param-tuning-dashboard"

    if [[ ! -f "$PLUGIN_DIR/build.mjs" ]]; then
        print_warn "TUI plugin build.mjs not found at $PLUGIN_DIR, skipping plugin deployment."
    elif ! command -v bun &>/dev/null; then
        print_warn "bun not found in PATH, skipping TUI plugin deployment."
        print_warn "Install bun (https://bun.sh) and run manually: cd $PLUGIN_DIR && bun run build.mjs --deploy ..."
    else
        echo ""
        print_info "Building and deploying TUI dashboard plugin..."

        # Determine deploy subcommand based on mode
        DEPLOY_ARGS=""
        case "$MODE" in
            global)
                DEPLOY_ARGS="global"
                ;;
            project)
                if [[ -n "$PROJECT_PATH" ]]; then
                    DEPLOY_ARGS="workspace $PROJECT_PATH"
                else
                    DEPLOY_ARGS="workspace $(pwd)"
                fi
                ;;
        esac

        # Save current directory, cd to plugin dir, build, then restore
        ORIG_DIR="$(pwd)"
        cd "$PLUGIN_DIR"
        bun install 2>&1 | tail -1
        if bun run build.mjs --deploy $DEPLOY_ARGS; then
            print_ok "TUI dashboard plugin deployed successfully."
        else
            print_warn "TUI plugin deployment failed. The skill is still installed."
            print_warn "You can manually build later: cd $PLUGIN_DIR && bun run build.mjs --deploy $DEPLOY_ARGS"
        fi
        cd "$ORIG_DIR"
    fi
fi

# --- Deploy stop-devkit server plugin (OpenCode modes only) ---
# 功能: ESC 停止当前任务时，同步终止残留的 devkit 训练进程。
# 部署: 复制到标准 auto-discovery 插件目录（plugins/），opencode 启动时自动加载。
if [[ "$MODE" != "devkitai" && -f "$STOP_DEVKIT_SRC" ]]; then
    if [[ "$MODE" == "global" ]]; then
        PLUGIN_DIR="$HOME/.config/opencode/plugins"
    elif [[ -n "$PROJECT_PATH" ]]; then
        PLUGIN_DIR="$PROJECT_PATH/.opencode/plugins"
    else
        PLUGIN_DIR="$(pwd)/.opencode/plugins"
    fi
    mkdir -p "$PLUGIN_DIR"
    cp "$STOP_DEVKIT_SRC" "$PLUGIN_DIR/stop-devkit-on-abort.js"
    print_ok "Deployed stop-devkit plugin to $PLUGIN_DIR/stop-devkit-on-abort.js"
fi

# --- Summary ---
echo ""
echo -e "${GREEN}============================================================${NC}"
echo -e "${GREEN} Installation Complete${NC}"
echo -e "${GREEN}============================================================${NC}"
echo -e "  Skill:  ${CYAN}$SKILL_NAME${NC}"
echo -e "  Scope:  ${CYAN}$SCOPE${NC}"
echo -e "  Path:   ${CYAN}$TARGET_DIR${NC}"
echo ""
if [[ "$MODE" == "global" ]]; then
    echo -e "  ${YELLOW}The skill is now available in all OpenCode projects.${NC}"
elif [[ "$MODE" == "devkitai" ]]; then
    echo -e "  ${YELLOW}The skill is now available for devkitai.${NC}"
    echo -e "  Restart devkitai or reload the session to activate the skill."
else
    if [[ -n "$PROJECT_PATH" ]]; then
        echo -e "  ${YELLOW}The skill is now available in: $PROJECT_PATH${NC}"
    else
        echo -e "  ${YELLOW}The skill is available in this project only.${NC}"
    fi
    echo -e "  Restart OpenCode or reload the session to activate the skill."
fi
echo ""
if [[ "$MODE" == "devkitai" ]]; then
    echo -e "  To use: invoke ${CYAN}/perf-params-tuner-agent${NC} in devkitai."
else
    echo -e "  To use: invoke ${CYAN}/perf-params-tuner-agent${NC} in OpenCode."
fi
