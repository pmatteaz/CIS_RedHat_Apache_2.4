#!/bin/bash

# Colori per l'output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Variabili per il conteggio
PASS=0
FAIL=0
WARN=0

# Variabili per il sistema operativo e Apache
OS_TYPE=""
APACHE_SERVICE=""
APACHE_USER=""
APACHE_GROUP=""
APACHE_DIR=""
APACHE_CONF=""
APACHE_CONF_DIR=""

# Funzione per rilevare il sistema operativo
detect_os() {
    if [ -f /etc/debian_version ]; then
        OS_TYPE="debian"
        APACHE_SERVICE="apache2"
        APACHE_USER="www-data"
        APACHE_GROUP="www-data"
        APACHE_DIR="/etc/apache2"
        APACHE_CONF="/etc/apache2/apache2.conf"
        APACHE_CONF_DIR="/etc/apache2/conf-enabled"
    elif [ -f /etc/redhat-release ]; then
        OS_TYPE="redhat"
        APACHE_SERVICE="httpd"
        APACHE_USER="apache"
        APACHE_GROUP="apache"
        APACHE_DIR="/etc/httpd"
        APACHE_CONF="/etc/httpd/conf/httpd.conf"
        APACHE_CONF_DIR="/etc/httpd/conf.d"
    else
        echo -e "${RED}Sistema operativo non supportato${NC}"
        exit 1
    fi
}

# Funzione per il logging
log_check() {
    local id="$1"
    local check_name="$2"
    local status="$3"
    local message="$4"
    
    case $status in
        "PASS")
            echo -e "${GREEN}[✓] $id $check_name${NC}"
            echo -e "    $message"
            ((PASS++))
            ;;
        "FAIL")
            echo -e "${RED}[✗] $id $check_name${NC}"
            echo -e "    $message"
            ((FAIL++))
            ;;
        "WARN")
            echo -e "${YELLOW}[!] $id $check_name${NC}"
            echo -e "    $message"
            ((WARN++))
            ;;
    esac
}

# 1. Initial Setup
check_basic_setup() {
    echo -e "\n${BLUE}=== 1. Initial Setup ===${NC}"
    
    # 1.1 Planning Considerations
    if [ -f "$APACHE_CONF" ]; then
        log_check "1.1" "Installation Planning" "PASS" "Apache configuration file exists"
    else
        log_check "1.1" "Installation Planning" "FAIL" "Apache configuration file not found"
    fi

    # 1.2 Verify Apache is Installed Correctly
    local apache_binary
    case $OS_TYPE in
        debian)
            apache_binary=$(which apache2)
            ;;
        redhat)
            apache_binary=$(which httpd)
            ;;
    esac
    
    if [ -n "$apache_binary" ] && [ -x "$apache_binary" ]; then
        log_check "1.2" "Apache Installation" "PASS" "Apache binary found and executable"
    else
        log_check "1.2" "Apache Installation" "FAIL" "Apache binary not found or not executable"
    fi
}

# 2. Minimize Apache Modules
check_modules() {
    echo -e "\n${BLUE}=== 2. Apache Modules ===${NC}"
    
    local required_modules=("log_config")
    local disabled_modules=("dav" "dav_fs" "autoindex" "userdir" "info" "auth_basic" "auth_digest")
    
    for module in "${required_modules[@]}"; do
        if is_module_enabled "$module"; then
            log_check "2.1" "Module $module" "PASS" "Required module is enabled"
        else
            log_check "2.1" "Module $module" "FAIL" "Required module should be enabled"
        fi
    done
    
    for module in "${disabled_modules[@]}"; do
        if ! is_module_enabled "$module"; then
            log_check "2.2" "Module $module" "PASS" "Dangerous module is disabled"
        else
            log_check "2.2" "Module $module" "FAIL" "Dangerous module should be disabled"
        fi
    done
}

# 3. Configure Authentication and Authorization
check_auth() {
    echo -e "\n${BLUE}=== 3. Authentication and Authorization ===${NC}"
    
    # Check for .htaccess files
    local htaccess_files=$(find / -name ".htaccess" 2>/dev/null)
    if [ -z "$htaccess_files" ]; then
        log_check "3.1" "htaccess Files" "PASS" "No .htaccess files found"
    else
        log_check "3.1" "htaccess Files" "WARN" "Found .htaccess files, verify they are necessary"
    fi
    
    # Check directory permissions
    for dir in $(find "$APACHE_DIR" -type d); do
        local perms=$(stat -c "%a" "$dir")
        if [ "$perms" -gt 755 ]; then
            log_check "3.2" "Directory Permissions" "FAIL" "Directory $dir has loose permissions: $perms"
        fi
    done
}

# 4. Configure Process Security
check_process_security() {
    echo -e "\n${BLUE}=== 4. Process Security ===${NC}"
    
    # Check Apache user
    if id "$APACHE_USER" >/dev/null 2>&1; then
        log_check "4.1" "Apache User" "PASS" "Apache user exists"
        
        # Check shell
        local shell=$(grep "^$APACHE_USER:" /etc/passwd | cut -d: -f7)
        if [[ "$shell" =~ nologin|false ]]; then
            log_check "4.2" "Apache Shell" "PASS" "Apache user has restricted shell"
        else
            log_check "4.2" "Apache Shell" "FAIL" "Apache user should have restricted shell"
        fi
    else
        log_check "4.1" "Apache User" "FAIL" "Apache user does not exist"
    fi
}

# 5. Configure Access Control
check_access_control() {
    echo -e "\n${BLUE}=== 5. Access Control ===${NC}"
    
    # Check root directory access
    if grep -R "^<Directory\s*/" "$APACHE_DIR" 2>/dev/null | grep -q "Deny from all"; then
        log_check "5.1" "Root Directory Access" "PASS" "Root directory access is denied"
    else
        log_check "5.1" "Root Directory Access" "FAIL" "Root directory access should be denied"
    fi
}

# 6. Configure TLS
check_tls() {
    echo -e "\n${BLUE}=== 6. TLS Configuration ===${NC}"
    
    local ssl_conf
    case $OS_TYPE in
        debian)
            ssl_conf="/etc/apache2/mods-enabled/ssl.conf"
            ;;
        redhat)
            ssl_conf="/etc/httpd/conf.d/ssl.conf"
            ;;
    esac
    
    if [ -f "$ssl_conf" ]; then
        # Check SSL protocols
        if grep -q "SSLProtocol.*all.*-SSLv3.*-TLSv1.*-TLSv1.1" "$ssl_conf"; then
            log_check "6.1" "SSL Protocols" "PASS" "Insecure protocols are disabled"
        else
            log_check "6.1" "SSL Protocols" "FAIL" "Insecure protocols may be enabled"
        fi
        
        # Check cipher configuration
        if grep -q "SSLCipherSuite.*HIGH:!MEDIUM:!LOW:!aNULL:!eNULL:!EXPORT:!DES:!RC4:!MD5:!PSK" "$ssl_conf"; then
            log_check "6.2" "SSL Ciphers" "PASS" "Strong cipher configuration"
        else
            log_check "6.2" "SSL Ciphers" "FAIL" "Weak ciphers may be enabled"
        fi
    else
        log_check "6.0" "SSL Configuration" "FAIL" "SSL configuration file not found"
    fi
}

# 7. Configure Logging
check_logging() {
    echo -e "\n${BLUE}=== 7. Logging Configuration ===${NC}"
    
    # Check LogLevel
    if grep -q "^LogLevel\s\+\(info\|notice\)" "$APACHE_CONF"; then
        log_check "7.1" "Log Level" "PASS" "Appropriate log level is set"
    else
        log_check "7.1" "Log Level" "FAIL" "Log level should be set to info or notice"
    fi
    
    # Check log rotation
    if [ -f "/etc/logrotate.d/apache2" ] || [ -f "/etc/logrotate.d/httpd" ]; then
        log_check "7.2" "Log Rotation" "PASS" "Log rotation is configured"
    else
        log_check "7.2" "Log Rotation" "FAIL" "Log rotation is not configured"
    fi
}

# 8. Configure Request Limits
check_request_limits() {
    echo -e "\n${BLUE}=== 8. Request Limits ===${NC}"
    
    local config_files=("$APACHE_CONF")
    [ -d "$APACHE_CONF_DIR" ] && config_files+=("$APACHE_CONF_DIR"/*.conf)
    
    local timeout_found=false
    local keepalive_found=false
    
    for conf in "${config_files[@]}"; do
        if [ -f "$conf" ]; then
            # Check Timeout
            if grep -q "^Timeout\s\+[0-9]\+$" "$conf"; then
                local timeout=$(grep "^Timeout" "$conf" | awk '{print $2}')
                if [ "$timeout" -le 10 ]; then
                    log_check "8.1" "Timeout" "PASS" "Timeout is set to $timeout seconds"
                else
                    log_check "8.1" "Timeout" "FAIL" "Timeout should be 10 seconds or less"
                fi
                timeout_found=true
            fi
            
            # Check KeepAlive
            if grep -q "^KeepAlive\s\+On" "$conf"; then
                keepalive_found=true
                log_check "8.2" "KeepAlive" "PASS" "KeepAlive is enabled"
            fi
        fi
    done
    
    [ "$timeout_found" = false ] && log_check "8.1" "Timeout" "FAIL" "Timeout directive not found"
    [ "$keepalive_found" = false ] && log_check "8.2" "KeepAlive" "FAIL" "KeepAlive directive not found"
}

# 9. Configure Information Disclosure Prevention
check_info_disclosure() {
    echo -e "\n${BLUE}=== 9. Information Disclosure Prevention ===${NC}"
    
    local config_files=("$APACHE_CONF")
    [ -d "$APACHE_CONF_DIR" ] && config_files+=("$APACHE_CONF_DIR"/*.conf)
    
    for conf in "${config_files[@]}"; do
        if [ -f "$conf" ]; then
            # Check ServerTokens
            if grep -q "^ServerTokens\s\+Prod" "$conf"; then
                log_check "9.1" "ServerTokens" "PASS" "ServerTokens is set to Prod"
            else
                log_check "9.1" "ServerTokens" "FAIL" "ServerTokens should be set to Prod"
            fi
            
            # Check ServerSignature
            if grep -q "^ServerSignature\s\+Off" "$conf"; then
                log_check "9.2" "ServerSignature" "PASS" "ServerSignature is disabled"
            else
                log_check "9.2" "ServerSignature" "FAIL" "ServerSignature should be disabled"
            fi
        fi
    done
}

# Funzione principale
main() {
    echo -e "${BLUE}=== APACHE CIS SECURITY BENCHMARK AUDIT ===${NC}"
    echo -e "Data: $(date)"
    
    # Verifica privilegi root
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Questo script deve essere eseguito come root${NC}"
        exit 1
    fi
    
    # Rileva il sistema operativo
    detect_os
    echo -e "Sistema operativo: ${BLUE}$OS_TYPE${NC}"
    echo -e "Directory Apache: ${BLUE}$APACHE_DIR${NC}"
    
    # Esegui tutti i controlli
    check_basic_setup
    check_modules
    check_auth
    check_process_security
    check_access_control
    check_tls
    check_logging
    check_request_limits
    check_info_disclosure
    
    # Report finale
    echo -e "\n${BLUE}=== REPORT FINALE ===${NC}"
    echo -e "Test superati: ${GREEN}$PASS${NC}"
    echo -e "Test falliti: ${RED}$FAIL${NC}"
    echo -e "Avvisi: ${YELLOW}$WARN${NC}"
    
    # Crea report in formato testo
    local report_file="apache_cis_audit_$(date +%Y%m%d_%H%M%S).txt"
    {
        echo "=== APACHE CIS SECURITY BENCHMARK AUDIT ==="
        echo "Data: $(date)"
        echo "Sistema operativo: $OS_TYPE"
        echo "Directory Apache: $APACHE_DIR"
        echo "Test superati: $PASS"
        echo "Test falliti: $FAIL"
        echo "Avvisi: $WARN"
    } > "$report_file"
    
    echo -e "\nReport salvato in: $report_file"
    
    # Exit con codice di errore se ci sono test falliti
    [ $FAIL -gt 0 ] && exit 1 || exit 0
}

# Esegui lo script
main

