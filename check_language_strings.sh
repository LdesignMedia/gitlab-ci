#!/bin/bash
#
# check_language_strings.sh
# 
# Script to check for missing language strings in Moodle code
# Scans for language string usage and verifies they exist in language files
# Can also check for missing translations in other language packs
#
# Author: LdesignMedia
# Usage: ./check_language_strings.sh [OPTIONS] [path_to_moodle] [component]
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
MISSING_TRANSLATIONS_COUNT=0

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Arrays to store findings
declare -A USED_STRINGS
declare -A STRING_LOCATIONS
declare -A ALL_DEFINED_STRINGS  # Union of all strings across all languages
declare -A LANGUAGE_STRINGS  # Tracks which strings exist in which language

# Plugin type mappings
declare -A PLUGIN_TYPES=(
    ["mod"]="mod"
    ["block"]="blocks"
    ["local"]="local"
    ["tool"]="admin/tool"
    ["theme"]="theme"
    ["auth"]="auth"
    ["enrol"]="enrol"
    ["repository"]="repository"
    ["qtype"]="question/type"
    ["qbehaviour"]="question/behaviour"
    ["qformat"]="question/format"
    ["assignsubmission"]="mod/assign/submission"
    ["assignfeedback"]="mod/assign/feedback"
    ["availability"]="availability/condition"
    ["filter"]="filter"
    ["editor"]="lib/editor"
    ["atto"]="lib/editor/atto/plugins"
    ["tinymce"]="lib/editor/tinymce/plugins"
    ["report"]="report"
    ["coursereport"]="course/report"
    ["gradeexport"]="grade/export"
    ["gradeimport"]="grade/import"
    ["gradereport"]="grade/report"
    ["gradingform"]="grade/grading/form"
    ["profilefield"]="user/profile/field"
    ["format"]="course/format"
    ["dataformat"]="dataformat"
    ["message"]="message/output"
    ["antivirus"]="lib/antivirus"
    ["media"]="media/player"
    ["search"]="search/engine"
)

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
    echo "  $0 /var/www/moodle                       # Auto-detect plugin and check everything"
    echo "  $0 /var/www/moodle mod_quiz              # Check specific module"
    echo "  $0 -v /var/www/moodle mod_forum          # Verbose output"
    echo "  $0 --unused /var/www/moodle local_plugin # Also check for unused strings"
}

# Function to log verbose messages
log_verbose() {
    [[ $VERBOSE -eq 1 ]] && echo "$1"
}

# Function to validate Moodle installation
validate_moodle_installation() {
    if [[ ! -d "$MOODLE_PATH" ]]; then
        echo -e "${RED}Error: Moodle directory not found: $MOODLE_PATH${NC}"
        exit 2
    fi
    
    if [[ ! -f "$MOODLE_PATH/version.php" ]]; then
        echo -e "${RED}Error: Not a valid Moodle installation: $MOODLE_PATH${NC}"
        exit 2
    fi
}

# Function to get plugin type from component name
get_plugin_type_from_component() {
    local component="$1"
    local prefix="${component%%_*}"
    echo "$prefix"
}

# Function to get plugin name from component
get_plugin_name_from_component() {
    local component="$1"
    echo "${component#*_}"
}

# Function to get plugin path from component name
get_plugin_path_from_component() {
    local component="$1"
    local plugin_type=$(get_plugin_type_from_component "$component")
    local plugin_name=$(get_plugin_name_from_component "$component")
    
    if [[ -n "${PLUGIN_TYPES[$plugin_type]}" ]]; then
        echo "${PLUGIN_TYPES[$plugin_type]}/$plugin_name"
    fi
}

# Function to get component from plugin path
get_component_from_path() {
    local filepath="$1"
    filepath="${filepath#$MOODLE_PATH/}"
    
    # Check each plugin type pattern
    for prefix in "${!PLUGIN_TYPES[@]}"; do
        local path_pattern="${PLUGIN_TYPES[$prefix]}"
        if [[ "$filepath" =~ ^$path_pattern/([^/]+)/ ]]; then
            echo "${prefix}_${BASH_REMATCH[1]}"
            return
        fi
    done
    
    # Return empty if no match (skip core files)
    echo ""
}

# Function to auto-detect component from current directory
auto_detect_component() {
    if [[ -f "$CI_PROJECT_DIR/version.php" ]]; then
        local component=$(grep -E "^\s*\\\$plugin->component\s*=\s*['\"]" "$CI_PROJECT_DIR/version.php" | sed -E "s/.*['\"]([^'\"]+)['\"].*/\1/")
        if [[ -n "$component" ]]; then
            echo "$component"
            return
        fi
    fi
    echo ""
}

# Function to get language file path for a component
get_language_file_path() {
    local component="$1"
    local language="$2"
    
    local plugin_path=$(get_plugin_path_from_component "$component")
    if [[ -n "$plugin_path" ]]; then
        echo "$MOODLE_PATH/$plugin_path/lang/$language/$component.php"
    fi
}

# Function to find all available languages for a component
find_available_languages() {
    local component="$1"
    local languages=""
    
    local plugin_path=$(get_plugin_path_from_component "$component")
    if [[ -n "$plugin_path" ]]; then
        for lang_dir in "$MOODLE_PATH/$plugin_path/lang"/*; do
            if [[ -d "$lang_dir" ]]; then
                local lang_code=$(basename "$lang_dir")
                languages="$languages,$lang_code"
            fi
        done
    fi
    
    echo "${languages#,}"  # Remove leading comma
}

# Function to scan PHP files for get_string calls
scan_php_file_for_strings() {
    local file="$1"
    
    # Pattern 1: get_string('identifier', 'component')
    grep -Hn "get_string\s*(\s*['\"]" "$file" 2>/dev/null | while IFS=: read -r line_num line_content; do
        if [[ "$line_content" =~ get_string\s*\(\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"]\s*,\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"] ]]; then
            local string_id="${BASH_REMATCH[1]}"
            local component="${BASH_REMATCH[2]}"
            USED_STRINGS["${component}:${string_id}"]=1
            STRING_LOCATIONS["${component}:${string_id}"]="${file}:${line_num}"
            log_verbose "    Found: ${component}:${string_id}"
        elif [[ "$line_content" =~ get_string\s*\(\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"] ]]; then
            local string_id="${BASH_REMATCH[1]}"
            local component=$(get_component_from_path "$file")
            if [[ -n "$component" ]]; then  # Skip if component is empty (core files)
                USED_STRINGS["${component}:${string_id}"]=1
                STRING_LOCATIONS["${component}:${string_id}"]="${file}:${line_num}"
                log_verbose "    Found: ${component}:${string_id} (implicit component)"
            fi
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
}

# Function to scan Mustache templates
scan_mustache_file_for_strings() {
    local file="$1"
    
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
}

# Function to scan JavaScript files
scan_javascript_file_for_strings() {
    local file="$1"
    
    # Pattern 1: M.util.get_string('identifier', 'component')
    grep -Hn "M\.util\.get_string\s*(" "$file" 2>/dev/null | while IFS=: read -r line_num line_content; do
        if [[ "$line_content" =~ M\.util\.get_string\s*\(\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"]\s*,\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"] ]]; then
            local string_id="${BASH_REMATCH[1]}"
            local component="${BASH_REMATCH[2]}"
            USED_STRINGS["${component}:${string_id}"]=1
            STRING_LOCATIONS["${component}:${string_id}"]="${file}:${line_num}"
            log_verbose "    Found: ${component}:${string_id}"
        fi
    done
    
    # Pattern 2: getString('identifier', 'component')
    grep -Hn "getString\s*(" "$file" 2>/dev/null | while IFS=: read -r line_num line_content; do
        if [[ "$line_content" =~ getString\s*\(\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"]\s*,\s*[\'\"]([-_a-zA-Z0-9]+)[\'\"] ]]; then
            local string_id="${BASH_REMATCH[1]}"
            local component="${BASH_REMATCH[2]}"
            USED_STRINGS["${component}:${string_id}"]=1
            STRING_LOCATIONS["${component}:${string_id}"]="${file}:${line_num}"
            log_verbose "    Found: ${component}:${string_id}"
        fi
    done
}

# Function to scan all files in a path
scan_path_for_strings() {
    local search_path="$1"
    
    log_verbose "Scanning for language strings in: $search_path"
    
    # Scan PHP files
    find "$search_path" -name "*.php" -type f 2>/dev/null | grep -v "/vendor/" | grep -v "/node_modules/" | while read -r file; do
        log_verbose "  Checking: $file"
        scan_php_file_for_strings "$file"
        
        # Check if it's a language file and load definitions
        if [[ "$file" =~ /lang/.*/.*\.php$ ]]; then
            local component=$(get_component_from_path "$file")
            if [[ -n "$component" ]]; then  # Skip if component is empty (core files)
                grep "^\s*\$string\[['\"]" "$file" 2>/dev/null | while read -r line; do
                    if [[ "$line" =~ \$string\[[\'\"]([-_a-zA-Z0-9]+)[\'\"] ]]; then
                        local string_id="${BASH_REMATCH[1]}"
                        ALL_DEFINED_STRINGS["${component}:${string_id}"]=1
                        log_verbose "    Language file defines: ${component}:${string_id}"
                    fi
                done
            fi
        fi
    done
    
    # Scan Mustache templates
    find "$search_path" -name "*.mustache" -type f 2>/dev/null | grep -v "/vendor/" | grep -v "/node_modules/" | while read -r file; do
        log_verbose "  Checking: $file"
        scan_mustache_file_for_strings "$file"
    done
    
    # Scan JavaScript files
    find "$search_path" -name "*.js" -type f 2>/dev/null | grep -v "/vendor/" | grep -v "/node_modules/" | grep -v "/lib/yui/" | while read -r file; do
        log_verbose "  Checking: $file"
        scan_javascript_file_for_strings "$file"
    done
}



# Function to load strings from a language file into the union set
load_strings_to_union() {
    local lang_file="$1"
    local component="$2"
    local language="$3"
    
    [[ ! -f "$lang_file" ]] && return
    
    log_verbose "  Loading $language strings from: $lang_file"
    
    grep "^\s*\$string\[['\"]" "$lang_file" 2>/dev/null | while read -r line; do
        if [[ "$line" =~ \$string\[[\'\"]([-_a-zA-Z0-9]+)[\'\"] ]]; then
            local string_id="${BASH_REMATCH[1]}"
            # Add to union of all strings
            ALL_DEFINED_STRINGS["${component}:${string_id}"]=1
            # Track which language has this string
            LANGUAGE_STRINGS["${language}:${component}:${string_id}"]=1
        fi
    done
}

# Function to build union of all strings from all languages for a component
build_component_string_union() {
    local component="$1"
    
    local plugin_path=$(get_plugin_path_from_component "$component")
    if [[ -n "$plugin_path" ]]; then
        # Check all language directories for this plugin
        for lang_dir in "$MOODLE_PATH/$plugin_path/lang"/*; do
            if [[ -d "$lang_dir" ]]; then
                local lang_code=$(basename "$lang_dir")
                # Load all PHP files in the language directory
                for lang_file in "$lang_dir"/*.php; do
                    if [[ -f "$lang_file" ]]; then
                        load_strings_to_union "$lang_file" "$component" "$lang_code"
                    fi
                done
            fi
        done
    fi
}


# Function to check missing strings
check_missing_strings() {
    echo ""
    echo "Checking for missing language strings in code..."
    echo ""
    
    # Always use the union set as reference
    for key in "${!USED_STRINGS[@]}"; do
        if [[ -z "${ALL_DEFINED_STRINGS[$key]}" ]]; then
            ((MISSING_COUNT++))
            echo -e "${RED}MISSING:${NC} $key (not defined in any language)"
            echo -e "  Location: ${STRING_LOCATIONS[$key]}"
        fi
    done
}

# Function to check unused strings
check_unused_strings() {
    [[ $CHECK_UNUSED -eq 0 ]] && return
    
    echo ""
    echo "Checking for potentially unused language strings..."
    echo ""
    
    for key in "${!FOUND_STRINGS[@]}"; do
        if [[ -z "${USED_STRINGS[$key]}" ]]; then
            ((UNUSED_COUNT++))
            echo -e "${YELLOW}POSSIBLY UNUSED:${NC} $key"
        fi
    done
}

# Function to check translation completeness
check_translation_completeness() {
    echo ""
    echo "Checking translation completeness across all languages..."
    echo ""
    
    # Get all available languages
    local languages_to_check=$(find_available_languages "$COMPONENT")
    
    if [[ -z "$languages_to_check" ]]; then
        echo "No language files found in plugin."
        return
    fi
    
    echo "Languages found: $languages_to_check"
    echo "Total unique strings in union: ${#ALL_DEFINED_STRINGS[@]}"
    echo ""
    
    # Check each language against the union
    IFS=',' read -ra LANG_ARRAY <<< "$languages_to_check"
    
    for lang in "${LANG_ARRAY[@]}"; do
        lang=$(echo "$lang" | tr -d ' ')
        [[ -z "$lang" ]] && continue
        
        echo ""
        echo "Language: $lang"
        echo "========================================"
        
        local lang_missing_count=0
        local lang_has_count=0
        
        # Check which strings from the union exist in this language
        for key in "${!ALL_DEFINED_STRINGS[@]}"; do
            if [[ -z "${LANGUAGE_STRINGS[$lang:$key]}" ]]; then
                ((lang_missing_count++))
                ((MISSING_TRANSLATIONS_COUNT++))
                echo -e "${RED}MISSING:${NC} $key"
                
                # Show which languages have this string
                local has_in_langs=""
                for check_lang in "${LANG_ARRAY[@]}"; do
                    check_lang=$(echo "$check_lang" | tr -d ' ')
                    if [[ -n "${LANGUAGE_STRINGS[$check_lang:$key]}" ]]; then
                        has_in_langs="$has_in_langs $check_lang"
                    fi
                done
                [[ -n "$has_in_langs" ]] && echo -e "  Available in:$has_in_langs"
            else
                ((lang_has_count++))
            fi
        done
        
        echo ""
        echo "Summary for $lang:"
        echo "  Defined: $lang_has_count"
        echo -e "  Missing: ${RED}$lang_missing_count${NC}"
        local coverage=$((lang_has_count * 100 / ${#ALL_DEFINED_STRINGS[@]}))
        echo "  Coverage: $coverage%"
        
        if [[ $lang_missing_count -eq 0 ]]; then
            echo -e "${GREEN}✓ Complete translation!${NC}"
        fi
    done
}

# Function to display summary
display_summary() {
    echo ""
    echo "Summary"
    echo "======="
    echo "Strings used in code: ${#USED_STRINGS[@]}"
    echo "Total unique strings across all languages: ${#ALL_DEFINED_STRINGS[@]}"
    echo -e "Missing strings (not defined in any language): ${RED}$MISSING_COUNT${NC}"
    echo -e "Total missing translations: ${RED}$MISSING_TRANSLATIONS_COUNT${NC}"
    
    [[ $CHECK_UNUSED -eq 1 ]] && echo -e "Possibly unused strings: ${YELLOW}$UNUSED_COUNT${NC}"
}

# Function to determine exit status
determine_exit_status() {
    if [[ $MISSING_COUNT -gt 0 ]] || [[ $MISSING_TRANSLATIONS_COUNT -gt 0 ]]; then
        echo ""
        [[ $MISSING_COUNT -gt 0 ]] && echo -e "${RED}ERROR: Missing language strings detected!${NC}"
        [[ $MISSING_TRANSLATIONS_COUNT -gt 0 ]] && echo -e "${RED}ERROR: Missing translations detected!${NC}"
        exit 1
    fi
    
    echo ""
    echo -e "${GREEN}SUCCESS: All language strings found!${NC}"
    [[ $CHECK_TRANSLATIONS -eq 1 ]] && echo -e "${GREEN}SUCCESS: All translations complete!${NC}"
    exit 0
}

# Main execution function
main() {
    echo "Moodle Language String Checker"
    echo "=============================="
    echo "Moodle path: $MOODLE_PATH"
    [[ -n "$COMPONENT" ]] && echo "Component: $COMPONENT"
    echo ""
    
    # Validate Moodle installation
    validate_moodle_installation
    
    # Determine search paths
    local search_paths=()
    if [[ -n "$COMPONENT" ]]; then
        local plugin_path=$(get_plugin_path_from_component "$COMPONENT")
        if [[ -n "$plugin_path" ]]; then
            search_paths=("$MOODLE_PATH/$plugin_path")
        else
            echo -e "${RED}Error: Unknown component type: $COMPONENT${NC}"
            exit 2
        fi
    else
        # Auto-detect component from current directory
        COMPONENT=$(auto_detect_component)
        if [[ -n "$COMPONENT" ]]; then
            echo "Auto-detected component: $COMPONENT"
            local plugin_path=$(get_plugin_path_from_component "$COMPONENT")
            if [[ -n "$plugin_path" ]]; then
                search_paths=("$MOODLE_PATH/$plugin_path")
            else
                echo -e "${RED}Error: Could not determine plugin path for: $COMPONENT${NC}"
                exit 2
            fi
        else
            echo -e "${RED}Error: Could not detect component. Please specify a component or run from a plugin directory.${NC}"
            exit 2
        fi
    fi
    
    # Scan for used strings
    echo "Scanning for language string usage..."
    for path in "${search_paths[@]}"; do
        if [[ -d "$path" ]]; then
            scan_path_for_strings "$path"
        else
            echo -e "${YELLOW}Warning: Path not found: $path${NC}"
        fi
    done
    
    # Build the union of all strings from all languages
    echo "Building union of language strings from all languages..."
    build_component_string_union "$COMPONENT"
    
    # Perform all checks
    check_missing_strings
    check_translation_completeness
    check_unused_strings
    
    # Display summary and exit
    display_summary
    determine_exit_status
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

# Run main function
main