#!/bin/bash
#
# check_language_strings.sh
# 
# Script to check for missing language strings in Moodle code
# Scans for language string usage and verifies they exist in language files
#
# Author: LdesignMedia
# Usage: ./check_language_strings.sh [path_to_moodle] [component]
#
# Exit codes:
# 0 - All language strings found
# 1 - Missing language strings detected
# 2 - Script error or invalid parameters

# Default values
MOODLE_PATH="${1:-/var/www/html}"
COMPONENT="${2:-}"  # Optional: specific component to check (e.g., mod_forum, local_plugin)
VERBOSE=0
CHECK_UNUSED=0
MISSING_COUNT=0
UNUSED_COUNT=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Arrays to store findings
declare -A USED_STRINGS
declare -A FOUND_STRINGS
declare -A STRING_LOCATIONS

# Function to display usage
usage() {
    echo "Usage: $0 [OPTIONS] [MOODLE_PATH] [COMPONENT]"
    echo ""
    echo "Options:"
    echo "  -v, --verbose     Show detailed output"
    echo "  -u, --unused      Also check for potentially unused language strings"
    echo "  -h, --help        Display this help message"
    echo ""
    echo "Arguments:"
    echo "  MOODLE_PATH       Path to Moodle installation (default: /var/www/html)"
    echo "  COMPONENT         Specific component to check (e.g., mod_forum)"
    echo ""
    echo "Examples:"
    echo "  $0 /var/www/moodle"
    echo "  $0 -v /var/www/moodle mod_quiz"
    echo "  $0 --unused /var/www/moodle local_myplugin"
}

# Parse command line options
while [[ $# -gt 0 ]]; do
    case $1 in
        -v|--verbose)
            VERBOSE=1
            shift
            ;;
        -u|--unused)
            CHECK_UNUSED=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            usage
            exit 2
            ;;
        *)
            if [[ -z "$MOODLE_PATH" ]]; then
                MOODLE_PATH="$1"
            elif [[ -z "$COMPONENT" ]]; then
                COMPONENT="$1"
            fi
            shift
            ;;
    esac
done

# Verify Moodle directory exists
if [[ ! -d "$MOODLE_PATH" ]]; then
    echo -e "${RED}Error: Moodle directory not found: $MOODLE_PATH${NC}"
    exit 2
fi

# Verify it's a Moodle installation
if [[ ! -f "$MOODLE_PATH/version.php" ]]; then
    echo -e "${RED}Error: Not a valid Moodle installation: $MOODLE_PATH${NC}"
    exit 2
fi

# Function to log verbose messages
log_verbose() {
    if [[ $VERBOSE -eq 1 ]]; then
        echo "$1"
    fi
}

# Function to extract component from file path
get_component_from_path() {
    local filepath="$1"
    local component=""
    
    # Remove MOODLE_PATH prefix
    filepath="${filepath#$MOODLE_PATH/}"
    
    # Determine component based on path
    if [[ "$filepath" =~ ^mod/([^/]+)/ ]]; then
        component="mod_${BASH_REMATCH[1]}"
    elif [[ "$filepath" =~ ^blocks/([^/]+)/ ]]; then
        component="block_${BASH_REMATCH[1]}"
    elif [[ "$filepath" =~ ^local/([^/]+)/ ]]; then
        component="local_${BASH_REMATCH[1]}"
    elif [[ "$filepath" =~ ^admin/tool/([^/]+)/ ]]; then
        component="tool_${BASH_REMATCH[1]}"
    elif [[ "$filepath" =~ ^theme/([^/]+)/ ]]; then
        component="theme_${BASH_REMATCH[1]}"
    elif [[ "$filepath" =~ ^auth/([^/]+)/ ]]; then
        component="auth_${BASH_REMATCH[1]}"
    elif [[ "$filepath" =~ ^enrol/([^/]+)/ ]]; then
        component="enrol_${BASH_REMATCH[1]}"
    elif [[ "$filepath" =~ ^repository/([^/]+)/ ]]; then
        component="repository_${BASH_REMATCH[1]}"
    elif [[ "$filepath" =~ ^question/type/([^/]+)/ ]]; then
        component="qtype_${BASH_REMATCH[1]}"
    elif [[ "$filepath" =~ ^question/behaviour/([^/]+)/ ]]; then
        component="qbehaviour_${BASH_REMATCH[1]}"
    elif [[ "$filepath" =~ ^grade/([^/]+)/ ]]; then
        component="core_grades"
    elif [[ "$filepath" =~ ^lib/ ]] || [[ "$filepath" =~ ^lang/ ]]; then
        component="core"
    else
        # Try to extract from first directory
        component=$(echo "$filepath" | cut -d'/' -f1)
        if [[ -z "$component" ]]; then
            component="core"
        fi
    fi
    
    echo "$component"
}

# Function to scan PHP files for language strings
scan_php_strings() {
    local search_path="$1"
    log_verbose "Scanning PHP files in: $search_path"
    
    # Find all PHP files
    while IFS= read -r file; do
        log_verbose "  Checking: $file"
        
        # Extract get_string calls with various patterns
        # Pattern 1: get_string('identifier', 'component')
        grep -Hn "get_string\s*(\s*['\"]" "$file" 2>/dev/null | while IFS=: read -r line_num line_content; do
            if [[ "$line_content" =~ get_string\s*\(\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"]\s*,\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"] ]]; then
                local string_id="${BASH_REMATCH[1]}"
                local component="${BASH_REMATCH[2]}"
                USED_STRINGS["${component}:${string_id}"]=1
                STRING_LOCATIONS["${component}:${string_id}"]="${file}:${line_num}"
                log_verbose "    Found: ${component}:${string_id}"
            elif [[ "$line_content" =~ get_string\s*\(\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"] ]]; then
                # get_string with only identifier (uses current component)
                local string_id="${BASH_REMATCH[1]}"
                local component=$(get_component_from_path "$file")
                USED_STRINGS["${component}:${string_id}"]=1
                STRING_LOCATIONS["${component}:${string_id}"]="${file}:${line_num}"
                log_verbose "    Found: ${component}:${string_id} (implicit component)"
            fi
        done
        
        # Pattern 2: new lang_string('identifier', 'component')
        grep -Hn "new\s\+lang_string\s*(\s*['\"]" "$file" 2>/dev/null | while IFS=: read -r line_num line_content; do
            if [[ "$line_content" =~ new\s+lang_string\s*\(\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"]\s*,\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"] ]]; then
                local string_id="${BASH_REMATCH[1]}"
                local component="${BASH_REMATCH[2]}"
                USED_STRINGS["${component}:${string_id}"]=1
                STRING_LOCATIONS["${component}:${string_id}"]="${file}:${line_num}"
                log_verbose "    Found: ${component}:${string_id}"
            fi
        done
        
        # Pattern 3: $string['identifier'] assignments in lang files
        if [[ "$file" =~ /lang/.*/.*\.php$ ]]; then
            grep -Hn "^\s*\$string\[['\"]" "$file" 2>/dev/null | while IFS=: read -r line_num line_content; do
                if [[ "$line_content" =~ \$string\[[\'\"]([-_a-zA-Z0-9]+)[\'\"] ]]; then
                    local string_id="${BASH_REMATCH[1]}"
                    local component=$(get_component_from_path "$file")
                    FOUND_STRINGS["${component}:${string_id}"]=1
                    log_verbose "    Language file defines: ${component}:${string_id}"
                fi
            done
        fi
    done < <(find "$search_path" -name "*.php" -type f 2>/dev/null | grep -v "/vendor/" | grep -v "/node_modules/")
}

# Function to scan Mustache templates
scan_mustache_strings() {
    local search_path="$1"
    log_verbose "Scanning Mustache templates in: $search_path"
    
    while IFS= read -r file; do
        log_verbose "  Checking: $file"
        
        # Pattern: {{#str}} identifier, component {{/str}}
        grep -Hn "{{#str}}" "$file" 2>/dev/null | while IFS=: read -r line_num line_content; do
            if [[ "$line_content" =~ \{\{#str\}\}\s*([-_a-zA-Z0-9]+)\s*,\s*([-_a-zA-Z0-9]+)\s*\{\{/str\}\} ]]; then
                local string_id="${BASH_REMATCH[1]}"
                local component="${BASH_REMATCH[2]}"
                USED_STRINGS["${component}:${string_id}"]=1
                STRING_LOCATIONS["${component}:${string_id}"]="${file}:${line_num}"
                log_verbose "    Found: ${component}:${string_id}"
            fi
        done
        
        # Pattern: {{#pix}} with title attribute
        grep -Hn "{{#pix}}.*title=" "$file" 2>/dev/null | while IFS=: read -r line_num line_content; do
            if [[ "$line_content" =~ title=\"\{\{#str\}\}\s*([-_a-zA-Z0-9]+)\s*,\s*([-_a-zA-Z0-9]+)\s*\{\{/str\}\}\" ]]; then
                local string_id="${BASH_REMATCH[1]}"
                local component="${BASH_REMATCH[2]}"
                USED_STRINGS["${component}:${string_id}"]=1
                STRING_LOCATIONS["${component}:${string_id}"]="${file}:${line_num}"
                log_verbose "    Found in pix title: ${component}:${string_id}"
            fi
        done
    done < <(find "$search_path" -name "*.mustache" -type f 2>/dev/null | grep -v "/vendor/" | grep -v "/node_modules/")
}

# Function to scan JavaScript files
scan_javascript_strings() {
    local search_path="$1"
    log_verbose "Scanning JavaScript files in: $search_path"
    
    while IFS= read -r file; do
        log_verbose "  Checking: $file"
        
        # Pattern: M.util.get_string('identifier', 'component')
        grep -Hn "M\.util\.get_string\s*(" "$file" 2>/dev/null | while IFS=: read -r line_num line_content; do
            if [[ "$line_content" =~ M\.util\.get_string\s*\(\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"]\s*,\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"] ]]; then
                local string_id="${BASH_REMATCH[1]}"
                local component="${BASH_REMATCH[2]}"
                USED_STRINGS["${component}:${string_id}"]=1
                STRING_LOCATIONS["${component}:${string_id}"]="${file}:${line_num}"
                log_verbose "    Found: ${component}:${string_id}"
            fi
        done
        
        # Pattern: getString('identifier', 'component') from core/str
        grep -Hn "getString\s*(" "$file" 2>/dev/null | while IFS=: read -r line_num line_content; do
            if [[ "$line_content" =~ getString\s*\(\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"]\s*,\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"] ]]; then
                local string_id="${BASH_REMATCH[1]}"
                local component="${BASH_REMATCH[2]}"
                USED_STRINGS["${component}:${string_id}"]=1
                STRING_LOCATIONS["${component}:${string_id}"]="${file}:${line_num}"
                log_verbose "    Found: ${component}:${string_id}"
            fi
        done
        
        # Pattern: {key: 'identifier', component: 'component'} in getStrings
        grep -Hn "key\s*:\s*['\"]" "$file" 2>/dev/null | while IFS=: read -r line_num line_content; do
            if [[ "$line_content" =~ key\s*:\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"]\s*,\s*component\s*:\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"] ]]; then
                local string_id="${BASH_REMATCH[1]}"
                local component="${BASH_REMATCH[2]}"
                USED_STRINGS["${component}:${string_id}"]=1
                STRING_LOCATIONS["${component}:${string_id}"]="${file}:${line_num}"
                log_verbose "    Found: ${component}:${string_id}"
            fi
        done
    done < <(find "$search_path" -name "*.js" -type f 2>/dev/null | grep -v "/vendor/" | grep -v "/node_modules/" | grep -v "/lib/yui/")
}

# Function to load language strings from PHP files
load_language_strings() {
    local lang_file="$1"
    local component="$2"
    
    if [[ -f "$lang_file" ]]; then
        log_verbose "  Loading strings from: $lang_file"
        
        # Extract string definitions
        grep "^\s*\$string\[['\"]" "$lang_file" 2>/dev/null | while read -r line; do
            if [[ "$line" =~ \$string\[[\'\"]([-_a-zA-Z0-9]+)[\'\"] ]]; then
                local string_id="${BASH_REMATCH[1]}"
                FOUND_STRINGS["${component}:${string_id}"]=1
            fi
        done
    fi
}

# Main scanning logic
echo "Moodle Language String Checker"
echo "=============================="
echo "Moodle path: $MOODLE_PATH"
if [[ -n "$COMPONENT" ]]; then
    echo "Component: $COMPONENT"
fi
echo ""

# Determine search paths based on component
if [[ -n "$COMPONENT" ]]; then
    # Specific component requested
    case "$COMPONENT" in
        mod_*)
            MODULE_NAME="${COMPONENT#mod_}"
            SEARCH_PATHS=("$MOODLE_PATH/mod/$MODULE_NAME")
            ;;
        block_*)
            BLOCK_NAME="${COMPONENT#block_}"
            SEARCH_PATHS=("$MOODLE_PATH/blocks/$BLOCK_NAME")
            ;;
        local_*)
            LOCAL_NAME="${COMPONENT#local_}"
            SEARCH_PATHS=("$MOODLE_PATH/local/$LOCAL_NAME")
            ;;
        tool_*)
            TOOL_NAME="${COMPONENT#tool_}"
            SEARCH_PATHS=("$MOODLE_PATH/admin/tool/$TOOL_NAME")
            ;;
        theme_*)
            THEME_NAME="${COMPONENT#theme_}"
            SEARCH_PATHS=("$MOODLE_PATH/theme/$THEME_NAME")
            ;;
        core)
            SEARCH_PATHS=("$MOODLE_PATH/lib" "$MOODLE_PATH/admin" "$MOODLE_PATH/course" "$MOODLE_PATH/user")
            ;;
        *)
            echo -e "${RED}Error: Unknown component type: $COMPONENT${NC}"
            exit 2
            ;;
    esac
else
    # Check entire Moodle installation
    SEARCH_PATHS=("$MOODLE_PATH")
fi

# Scan for used strings
echo "Scanning for language string usage..."
for path in "${SEARCH_PATHS[@]}"; do
    if [[ -d "$path" ]]; then
        scan_php_strings "$path"
        scan_mustache_strings "$path"
        scan_javascript_strings "$path"
    else
        echo -e "${YELLOW}Warning: Path not found: $path${NC}"
    fi
done

# Load available language strings
echo "Loading language file definitions..."
if [[ -n "$COMPONENT" ]]; then
    # Load strings for specific component
    case "$COMPONENT" in
        mod_*)
            MODULE_NAME="${COMPONENT#mod_}"
            load_language_strings "$MOODLE_PATH/mod/$MODULE_NAME/lang/en/$MODULE_NAME.php" "$COMPONENT"
            ;;
        block_*)
            BLOCK_NAME="${COMPONENT#block_}"
            load_language_strings "$MOODLE_PATH/blocks/$BLOCK_NAME/lang/en/block_$BLOCK_NAME.php" "$COMPONENT"
            ;;
        local_*)
            LOCAL_NAME="${COMPONENT#local_}"
            load_language_strings "$MOODLE_PATH/local/$LOCAL_NAME/lang/en/local_$LOCAL_NAME.php" "$COMPONENT"
            ;;
        tool_*)
            TOOL_NAME="${COMPONENT#tool_}"
            load_language_strings "$MOODLE_PATH/admin/tool/$TOOL_NAME/lang/en/tool_$TOOL_NAME.php" "$COMPONENT"
            ;;
        theme_*)
            THEME_NAME="${COMPONENT#theme_}"
            load_language_strings "$MOODLE_PATH/theme/$THEME_NAME/lang/en/theme_$THEME_NAME.php" "$COMPONENT"
            ;;
        core)
            # Load core language files
            for lang_file in "$MOODLE_PATH"/lang/en/*.php; do
                load_language_strings "$lang_file" "core"
            done
            ;;
    esac
else
    # Load all language files
    # Core strings
    for lang_file in "$MOODLE_PATH"/lang/en/*.php; do
        load_language_strings "$lang_file" "core"
    done
    
    # Module strings
    for mod_dir in "$MOODLE_PATH"/mod/*/lang/en; do
        if [[ -d "$mod_dir" ]]; then
            mod_name=$(basename "$(dirname "$(dirname "$mod_dir")")")
            load_language_strings "$mod_dir/$mod_name.php" "mod_$mod_name"
        fi
    done
    
    # Block strings
    for block_dir in "$MOODLE_PATH"/blocks/*/lang/en; do
        if [[ -d "$block_dir" ]]; then
            block_name=$(basename "$(dirname "$(dirname "$block_dir")")")
            load_language_strings "$block_dir/block_$block_name.php" "block_$block_name"
        fi
    done
    
    # Local plugins
    for local_dir in "$MOODLE_PATH"/local/*/lang/en; do
        if [[ -d "$local_dir" ]]; then
            local_name=$(basename "$(dirname "$(dirname "$local_dir")")")
            load_language_strings "$local_dir/local_$local_name.php" "local_$local_name"
        fi
    done
    
    # Admin tools
    for tool_dir in "$MOODLE_PATH"/admin/tool/*/lang/en; do
        if [[ -d "$tool_dir" ]]; then
            tool_name=$(basename "$(dirname "$(dirname "$tool_dir")")")
            load_language_strings "$tool_dir/tool_$tool_name.php" "tool_$tool_name"
        fi
    done
fi

# Check for missing strings
echo ""
echo "Checking for missing language strings..."
echo ""

for key in "${!USED_STRINGS[@]}"; do
    if [[ -z "${FOUND_STRINGS[$key]}" ]]; then
        ((MISSING_COUNT++))
        echo -e "${RED}MISSING:${NC} $key"
        echo -e "  Location: ${STRING_LOCATIONS[$key]}"
    fi
done

# Check for unused strings if requested
if [[ $CHECK_UNUSED -eq 1 ]]; then
    echo ""
    echo "Checking for potentially unused language strings..."
    echo ""
    
    for key in "${!FOUND_STRINGS[@]}"; do
        if [[ -z "${USED_STRINGS[$key]}" ]]; then
            ((UNUSED_COUNT++))
            echo -e "${YELLOW}POSSIBLY UNUSED:${NC} $key"
        fi
    done
fi

# Summary
echo ""
echo "Summary"
echo "======="
echo "Used strings found: ${#USED_STRINGS[@]}"
echo "Language strings defined: ${#FOUND_STRINGS[@]}"
echo -e "Missing strings: ${RED}$MISSING_COUNT${NC}"
if [[ $CHECK_UNUSED -eq 1 ]]; then
    echo -e "Possibly unused strings: ${YELLOW}$UNUSED_COUNT${NC}"
fi

# Exit with appropriate code
if [[ $MISSING_COUNT -gt 0 ]]; then
    echo ""
    echo -e "${RED}ERROR: Missing language strings detected!${NC}"
    exit 1
else
    echo ""
    echo -e "${GREEN}SUCCESS: All language strings found!${NC}"
    exit 0
fi