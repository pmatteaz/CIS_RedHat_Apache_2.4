#!/bin/bash

# Script per la verifica CIS Apache 2.4
# Basato sul CIS Apache HTTP Server 2.4 Benchmark

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0
ISSUES_FOUND=""
REMEDIATION_SUGGESTIONS=""


# Funzione per stampare risultati
print_result() {
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))
    if [ $2 -eq 0 ]; then
        echo -e "[${GREEN}PASS${NC}] $1"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        echo -e "[${RED}FAIL${NC}] $1"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
        ISSUES_FOUND+="❌ $1\n"
        # Aggiungi suggerimenti specifici per la correzione
        case "$1" in
            *"ServerTokens"*)
                REMEDIATION_SUGGESTIONS+="🔧 ServerTokens: Aggiungere 'ServerTokens Prod' nel file di configurazione\n"
                ;;
            *"SSL"*)
                REMEDIATION_SUGGESTIONS+="🔧 SSL/TLS: Verificare la configurazione SSL e aggiornare i protocolli e cipher suite\n"
                ;;
            *"Directory"*)
                REMEDIATION_SUGGESTIONS+="🔧 Directory: Rivedere i permessi delle directory e le configurazioni Options\n"
                ;;
            # Aggiungi altri casi specifici per i vari controlli
        esac
    fi
}

# Funzione per stampare sezioni
print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# Identifica la distribuzione
if [ -f /etc/debian_version ]; then
    DISTRO="debian"
    APACHE_PATH="/etc/apache2"
    APACHE_USER="www-data"
    APACHE_BIN="apache2"
    APACHE_CTL="apache2ctl"
elif [ -f /etc/redhat-release ]; then
    DISTRO="redhat"
    APACHE_PATH="/etc/httpd"
    APACHE_USER="apache"
    APACHE_BIN="httpd"
    APACHE_CTL="httpd"
else
    echo "Distribuzione non supportata"
    exit 1
fi

echo "=== CIS Apache HTTP Server 2.4 Benchmark Check ==="
echo "Distribuzione rilevata: $DISTRO"
date

# 1 Planning and Installation
print_section "1 Planning and Installation"

# 1.1 Ensure the Pre-Installation Planning Checklist Has Been Implemented
check_pre_inst(){
echo -e "${YELLOW}1.1 Pre-Installation Planning Checklist${NC}"
echo "Nota: Verifica manuale richiesta per la checklist di pre-installazione"
}

# 1.2 Ensure the Server Is Not a Multi-Use System
check_not_multi(){
print_section "1.2 Verifica Server Multi-Use"
other_services=$(systemctl list-units --type=service --state=active | grep -vE "apache2|httpd")
if [ -z "$other_services" ]; then
    print_result "1.2 Server dedicato solo ad Apache" 0
else
    print_result "1.2 Server utilizzato per altri servizi" 1
fi
}

# 1.3 Ensure Apache Is Installed From the Appropriate Binaries
check_inst_bin(){
print_section "1.3 Verifica Installazione Apache"
if [ "$DISTRO" = "debian" ]; then
    pkg_info=$(dpkg -s apache2 2>/dev/null)
    if [ $? -eq 0 ] && [[ "$pkg_info" =~ "ubuntu.com" ]] || [[ "$pkg_info" =~ "debian.org" ]]; then
        print_result "1.3 Apache installato da repository ufficiali" 0
    else
        print_result "1.3 Apache non installato da repository ufficiali" 1
    fi
else
    pkg_info=$(rpm -qi httpd 2>/dev/null)
    if [ $? -eq 0 ] && [[ "$pkg_info" =~ "redhat.com" ]]; then
        print_result "1.3 Apache installato da repository ufficiali" 0
    else
        print_result "1.3 Apache non installato da repository ufficiali" 1
    fi
fi
}
# Esegui tutte le verifiche della sezione 1
check_pre_inst
check_not_multi
check_inst_bin

# 2 Minimize Apache Modules
print_section "2 Minimize Apache Modules"

# 2.1 Ensure Only Necessary Authentication and Authorization Modules Are Enabled
check_auth_modules() {
    local auth_modules=("auth_basic_module" "auth_digest_module")
    local enabled_auth=0

    for mod in "${auth_modules[@]}"; do
        if [ "$DISTRO" = "debian" ]; then
            is_enabled=$(apache2ctl -M 2>/dev/null | grep -i "$mod")
        else
            is_enabled=$(httpd -M 2>/dev/null | grep -i "$mod")
        fi

        if [ -n "$is_enabled" ]; then
            enabled_auth=$((enabled_auth + 1))
        fi
    done

    if [ $enabled_auth -le 1 ]; then
        print_result "2.1 Solo moduli di autenticazione necessari abilitati" 0
    else
        print_result "2.1 Troppi moduli di autenticazione abilitati" 1
    fi
}

# 2.2 Ensure the Log Config Module Is Enabled
check_log_config() {
    if [ "$DISTRO" = "debian" ]; then
        log_mod=$(apache2ctl -M 2>/dev/null | grep -i "log_config_module")
    else
        log_mod=$(httpd -M 2>/dev/null | grep -i "log_config_module")
    fi

    if [ -n "$log_mod" ]; then
        print_result "2.2 Modulo log_config abilitato" 0
    else
        print_result "2.2 Modulo log_config non abilitato" 1
    fi
}

# 2.3 Ensure the WebDAV Modules Are Disabled
check_webdav_modules() {
    local webdav_enabled=0
    local webdav_modules=("dav_module" "dav_fs_module" "dav_lock_module")

    for mod in "${webdav_modules[@]}"; do
        if [ "$DISTRO" = "debian" ]; then
            is_enabled=$(apache2ctl -M 2>/dev/null | grep -i "$mod")
        else
            is_enabled=$(httpd -M 2>/dev/null | grep -i "$mod")
        fi

        if [ -n "$is_enabled" ]; then
            webdav_enabled=1
            break
        fi
    done

    if [ $webdav_enabled -eq 0 ]; then
        print_result "2.3 Moduli WebDAV disabilitati" 0
    else
        print_result "2.3 Moduli WebDAV abilitati" 1
    fi
}

# 2.4 Ensure the Status Module Is Disabled
check_status_module() {
    if [ "$DISTRO" = "debian" ]; then
        status_mod=$(apache2ctl -M 2>/dev/null | grep -i "status_module")
    else
        status_mod=$(httpd -M 2>/dev/null | grep -i "status_module")
    fi

    if [ -z "$status_mod" ]; then
        print_result "2.4 Modulo status disabilitato" 0
    else
        print_result "2.4 Modulo status abilitato" 1
    fi
}

# 2.5 Ensure the Autoindex Module Is Disabled
check_autoindex_module() {
    if [ "$DISTRO" = "debian" ]; then
        autoindex_mod=$(apache2ctl -M 2>/dev/null | grep -i "autoindex_module")
    else
        autoindex_mod=$(httpd -M 2>/dev/null | grep -i "autoindex_module")
    fi

    if [ -z "$autoindex_mod" ]; then
        print_result "2.5 Modulo autoindex disabilitato" 0
    else
        print_result "2.5 Modulo autoindex abilitato" 1
    fi
}

# 2.6 Ensure the Proxy Modules Are Disabled
check_proxy_modules() {
    local proxy_enabled=0
    local proxy_modules=("proxy_module" "proxy_balancer_module" "proxy_ftp_module" "proxy_http_module" "proxy_connect_module")

    for mod in "${proxy_modules[@]}"; do
        if [ "$DISTRO" = "debian" ]; then
            is_enabled=$(apache2ctl -M 2>/dev/null | grep -i "$mod")
        else
            is_enabled=$(httpd -M 2>/dev/null | grep -i "$mod")
        fi

        if [ -n "$is_enabled" ]; then
            proxy_enabled=1
            break
        fi
    done

    if [ $proxy_enabled -eq 0 ]; then
        print_result "2.6 Moduli proxy disabilitati" 0
    else
        print_result "2.6 Moduli proxy abilitati" 1
    fi
}

# 2.7 Ensure the User Directories Module Is Disabled
check_userdir_module() {
    if [ "$DISTRO" = "debian" ]; then
        userdir_mod=$(apache2ctl -M 2>/dev/null | grep -i "userdir_module")
    else
        userdir_mod=$(httpd -M 2>/dev/null | grep -i "userdir_module")
    fi

    if [ -z "$userdir_mod" ]; then
        print_result "2.7 Modulo userdir disabilitato" 0
    else
        print_result "2.7 Modulo userdir abilitato" 1
    fi
}

# 2.8 Ensure the Info Module Is Disabled
check_info_module() {
    if [ "$DISTRO" = "debian" ]; then
        info_mod=$(apache2ctl -M 2>/dev/null | grep -i "info_module")
    else
        info_mod=$(httpd -M 2>/dev/null | grep -i "info_module")
    fi

    if [ -z "$info_mod" ]; then
        print_result "2.8 Modulo info disabilitato" 0
    else
        print_result "2.8 Modulo info abilitato" 1
    fi
}

# 2.9 Ensure the Basic and Digest Authentication Modules are Disabled
check_auth_basic_digest() {
    local auth_enabled=0
    local auth_modules=("auth_basic_module" "auth_digest_module")

    for mod in "${auth_modules[@]}"; do
        if [ "$DISTRO" = "debian" ]; then
            is_enabled=$(apache2ctl -M 2>/dev/null | grep -i "$mod")
        else
            is_enabled=$(httpd -M 2>/dev/null | grep -i "$mod")
        fi

        if [ -n "$is_enabled" ]; then
            auth_enabled=1
            break
        fi
    done

    if [ $auth_enabled -eq 0 ]; then
        print_result "2.9 Moduli auth_basic e auth_digest disabilitati" 0
    else
        print_result "2.9 Moduli auth_basic o auth_digest abilitati" 1
    fi
}

# Esegui tutte le verifiche della sezione 2
check_auth_modules
check_log_config
check_webdav_modules
#check_status_module
check_autoindex_module
#check_proxy_modules
check_userdir_module
check_info_module
check_auth_basic_digest

# 3 Principles, Permissions, and Ownership
print_section "3 Principles, Permissions, and Ownership"

# 3.1 Ensure the Apache Web Server Runs As a Non-Root User
check_non_root_user() {
    local apache_user=""
    if [ "$DISTRO" = "debian" ]; then
        apache_user=$(grep -r "^User" $APACHE_PATH/apache2.conf | awk '{print $2}')
    else
        apache_user=$(grep -r "^User" $APACHE_PATH/conf/httpd.conf | awk '{print $2}')
    fi

    if [ "$apache_user" != "root" ] && [ -n "$apache_user" ]; then
        print_result "3.1 Apache non esegue come root" 0
    else
        print_result "3.1 Apache potrebbe eseguire come root" 1
    fi
}

# 3.2 Ensure the Apache User Account Has an Invalid Shell
check_invalid_shell() {
    local apache_shell=$(grep ^$APACHE_USER /etc/passwd | cut -d: -f7)

    if [ "$apache_shell" = "/sbin/nologin" ] || [ "$apache_shell" = "/usr/sbin/nologin" ] || [ "$apache_shell" = "/bin/false" ]; then
        print_result "3.2 Apache user ha shell non valida" 0
    else
        print_result "3.2 Apache user ha shell valida" 1
    fi
}

# 3.3 Ensure the Apache User Account Is Locked
check_locked_account() {
    local account_status=$(passwd -S $APACHE_USER 2>/dev/null | awk '{print $2}')

    if [ "$account_status" = "L" ] || [ "$account_status" = "LK" ]; then
        print_result "3.3 Account Apache bloccato" 0
    else
        print_result "3.3 Account Apache non bloccato" 1
    fi
}

# 3.4 Ensure Apache Directories and Files Are Owned By Root
check_root_ownership() {
    local incorrect_ownership=0

    # Verifica directory principali
    find "$APACHE_PATH" -type d -not -user root | while read -r dir; do
        incorrect_ownership=1
        echo "Directory non di proprietà di root: $dir"
    done

    # Verifica file di configurazione
    find "$APACHE_PATH" -type f -not -user root | while read -r file; do
        incorrect_ownership=1
        echo "File non di proprietà di root: $file"
    done

    if [ $incorrect_ownership -eq 0 ]; then
        print_result "3.4 Tutti i file e directory sono di proprietà di root" 0
    else
        print_result "3.4 Alcuni file o directory non sono di proprietà di root" 1
    fi
}

# 3.5 Ensure the Group Is Set Correctly on Apache Directories and Files
check_group_ownership() {
    local apache_group=""
    if [ "$DISTRO" = "debian" ]; then
        apache_group="www-data"
    else
        apache_group="apache"
    fi

    local incorrect_group=0

    find "$APACHE_PATH" -not -group $apache_group -and -not -group root | while read -r item; do
        incorrect_group=1
        echo "Item con gruppo errato: $item"
    done

    if [ $incorrect_group -eq 0 ]; then
        print_result "3.5 Gruppo impostato correttamente" 0
    else
        print_result "3.5 Gruppo non impostato correttamente su alcuni elementi" 1
    fi
}

# 3.6 Ensure Other Write Access on Apache Directories and Files Is Restricted
check_other_write_access() {
    local write_access_found=0

    find "$APACHE_PATH" -perm -o+w | while read -r item; do
        write_access_found=1
        echo "Accesso in scrittura per altri trovato su: $item"
    done

    if [ $write_access_found -eq 0 ]; then
        print_result "3.6 Nessun accesso in scrittura per altri" 0
    else
        print_result "3.6 Trovato accesso in scrittura per altri" 1
    fi
}

# 3.7 Ensure the Core Dump Directory Is Secured
check_core_dump_dir() {
    local core_dump_dir=""
    if [ "$DISTRO" = "debian" ]; then
        core_dump_dir=$(grep -r "CoreDumpDirectory" $APACHE_PATH/apache2.conf | awk '{print $2}')
    else
        core_dump_dir=$(grep -r "CoreDumpDirectory" $APACHE_PATH/conf/httpd.conf | awk '{print $2}')
    fi

    if [ -n "$core_dump_dir" ]; then
        local perms=$(stat -c %a "$core_dump_dir" 2>/dev/null)
        local owner=$(stat -c %U "$core_dump_dir" 2>/dev/null)

        if [ "$owner" = "root" ] && [ "$perms" = "700" ]; then
            print_result "3.7 Directory core dump configurata correttamente" 0
        else
            print_result "3.7 Directory core dump non sicura" 1
        fi
    else
        print_result "3.7 Directory core dump non configurata" 0
    fi
}

# 3.8 Ensure the Lock File Is Secured
check_lock_file() {
    local lock_file=""
    if [ "$DISTRO" = "debian" ]; then
        lock_file="/var/lock/apache2"
    else
        lock_file="/var/run/httpd.lock"
    fi

    if [ -f "$lock_file" ]; then
        local perms=$(stat -c %a "$lock_file")
        local owner=$(stat -c %U "$lock_file")

        if [ "$owner" = "root" ] && [ "$perms" = "600" ]; then
            print_result "3.8 File di lock configurato correttamente" 0
        else
            print_result "3.8 File di lock non sicuro" 1
        fi
    else
        print_result "3.8 File di lock non trovato" 0
    fi
}

# 3.9 Ensure the Pid File Is Secured
check_pid_file() {
    local pid_file=""
    if [ "$DISTRO" = "debian" ]; then
        pid_file="/var/run/apache2/apache2.pid"
    else
        pid_file="/var/run/httpd/httpd.pid"
    fi

    if [ -f "$pid_file" ]; then
        local perms=$(stat -c %a "$pid_file")
        local owner=$(stat -c %U "$pid_file")

        if [ "$owner" = "root" ] && [ "$perms" = "644" ]; then
            print_result "3.9 File pid configurato correttamente" 0
        else
            print_result "3.9 File pid non sicuro" 1
        fi
    else
        print_result "3.9 File pid non trovato" 0
    fi
}

# 3.10 Ensure the ScoreBoard File Is Secured
check_scoreboard_file() {
    local scoreboard_path=$(grep -r "ScoreBoardFile" "$APACHE_PATH" | awk '{print $2}')

    if [ -n "$scoreboard_path" ] && [ -f "$scoreboard_path" ]; then
        local perms=$(stat -c %a "$scoreboard_path")
        local owner=$(stat -c %U "$scoreboard_path")

        if [ "$owner" = "root" ] && [ "$perms" = "600" ]; then
            print_result "3.10 File scoreboard configurato correttamente" 0
        else
            print_result "3.10 File scoreboard non sicuro" 1
        fi
    else
        print_result "3.10 File scoreboard non trovato" 0
    fi
}

# 3.11 Ensure Group Write Access for the Apache Directories and Files Is Properly Restricted
check_group_write_access() {
    local group_write_found=0

    find "$APACHE_PATH" -perm -g+w | while read -r item; do
        group_write_found=1
        echo "Accesso in scrittura per il gruppo trovato su: $item"
    done

    if [ $group_write_found -eq 0 ]; then
        print_result "3.11 Nessun accesso in scrittura per il gruppo" 0
    else
        print_result "3.11 Trovato accesso in scrittura per il gruppo" 1
    fi
}

# 3.12 Ensure Group Write Access for the Document Root Directories and Files Is Properly Restricted
check_docroot_group_write() {
    local docroot=""
    if [ "$DISTRO" = "debian" ]; then
        docroot="/var/www/html"
    else
        docroot="/var/www/html"
    fi

    local group_write_found=0

    find "$docroot" -perm -g+w | while read -r item; do
        group_write_found=1
        echo "Accesso in scrittura per il gruppo trovato su: $item"
    done

    if [ $group_write_found -eq 0 ]; then
        print_result "3.12 Nessun accesso in scrittura per il gruppo nella DocumentRoot" 0
    else
        print_result "3.12 Trovato accesso in scrittura per il gruppo nella DocumentRoot" 1
    fi
}

# 3.13 Ensure Access to Special Purpose Application Writable Directories is Properly Restricted
check_special_directories() {
    local special_dirs=()

    # Cerca directory scrivibili nelle configurazioni dei virtual host
    if [ "$DISTRO" = "debian" ]; then
        special_dirs+=($(grep -r "Directory" /etc/apache2/sites-enabled/ | grep -i "writable" | awk '{print $2}'))
    else
        special_dirs+=($(grep -r "Directory" /etc/httpd/conf.d/ | grep -i "writable" | awk '{print $2}'))
    fi

    local issues_found=0

    for dir in "${special_dirs[@]}"; do
        if [ -d "$dir" ]; then
            local perms=$(stat -c %a "$dir")
            if [ "$perms" != "750" ]; then
                issues_found=1
                echo "Directory speciale con permessi non corretti: $dir ($perms)"
            fi
        fi
    done

    if [ $issues_found -eq 0 ]; then
        print_result "3.13 Directory speciali configurate correttamente" 0
    else
        print_result "3.13 Directory speciali non configurate correttamente" 1
    fi
}

# Esegui tutte le verifiche della sezione 3
check_non_root_user
check_invalid_shell
check_locked_account
check_root_ownership
check_group_ownership
check_other_write_access
check_core_dump_dir
check_lock_file
check_pid_file
check_scoreboard_file
check_group_write_access
check_docroot_group_write
check_special_directories

# 4 Apache Access Control
print_section "4 Apache Access Control"

# 4.1 Ensure Access to OS Root Directory Is Denied By Default
check_os_root_access() {
    local root_dir_conf=""
    if [ "$DISTRO" = "debian" ]; then
        root_dir_conf=$(grep -r "<Directory /" "$APACHE_PATH" | grep -v "html")
    else
        root_dir_conf=$(grep -r "<Directory /" "$APACHE_PATH" | grep -v "html")
    fi

    if [[ "$root_dir_conf" =~ "Require all denied" ]] || [[ "$root_dir_conf" =~ "deny from all" ]]; then
        print_result "4.1 Accesso alla directory root OS negato correttamente" 0
    else
        print_result "4.1 Accesso alla directory root OS non negato correttamente" 1
    fi
}

# 4.2 Ensure Appropriate Access to Web Content Is Allowed
check_web_content_access() {
    local doc_root=""
    local issues_found=0

    if [ "$DISTRO" = "debian" ]; then
        doc_root=$(grep -r "DocumentRoot" "$APACHE_PATH/sites-enabled/" | awk '{print $2}' | head -1)
    else
        doc_root=$(grep -r "DocumentRoot" "$APACHE_PATH/conf/httpd.conf" | awk '{print $2}' | head -1)
    fi

    if [ -d "$doc_root" ]; then
        # Verifica permessi directory
        local dir_perms=$(stat -c %a "$doc_root")
        if [ "$dir_perms" != "755" ]; then
            issues_found=1
            echo "DocumentRoot ha permessi non corretti: $dir_perms"
        fi

        # Verifica configurazione Directory
        local dir_conf=""
        if [ "$DISTRO" = "debian" ]; then
            dir_conf=$(grep -r "<Directory $doc_root>" "$APACHE_PATH" -A5)
        else
            dir_conf=$(grep -r "<Directory $doc_root>" "$APACHE_PATH" -A5)
        fi

        if ! [[ "$dir_conf" =~ "Require all granted" ]] && ! [[ "$dir_conf" =~ "allow from all" ]]; then
            issues_found=1
            echo "DocumentRoot non ha configurazioni di accesso appropriate"
        fi
    else
        issues_found=1
        echo "DocumentRoot non trovata: $doc_root"
    fi

    if [ $issues_found -eq 0 ]; then
        print_result "4.2 Accesso al contenuto web configurato correttamente" 0
    else
        print_result "4.2 Accesso al contenuto web non configurato correttamente" 1
    fi
}

# 4.3 Ensure OverRide Is Disabled for the OS Root Directory
check_root_override() {
    local root_dir_conf=""
    if [ "$DISTRO" = "debian" ]; then
        root_dir_conf=$(grep -r "<Directory /" "$APACHE_PATH" | grep -v "html")
    else
        root_dir_conf=$(grep -r "<Directory /" "$APACHE_PATH" | grep -v "html")
    fi

    if [[ "$root_dir_conf" =~ "AllowOverride None" ]]; then
        print_result "4.3 AllowOverride disabilitato per directory root OS" 0
    else
        print_result "4.3 AllowOverride non disabilitato per directory root OS" 1
    fi
}

# 4.4 Ensure OverRide Is Disabled for All Directories
check_all_directories_override() {
    local override_issues=0
    local dir_configs=""

    if [ "$DISTRO" = "debian" ]; then
        dir_configs=$(find "$APACHE_PATH" -type f -exec grep -l "<Directory" {} \;)
    else
        dir_configs=$(find "$APACHE_PATH" -type f -exec grep -l "<Directory" {} \;)
    fi

    for config in $dir_configs; do
        if grep -q "<Directory" "$config"; then
            if ! grep -q "AllowOverride None" "$config"; then
                override_issues=1
                echo "File $config non ha AllowOverride None configurato"
            fi
        fi
    done

    if [ $override_issues -eq 0 ]; then
        print_result "4.4 AllowOverride disabilitato per tutte le directory" 0
    else
        print_result "4.4 AllowOverride non disabilitato per tutte le directory" 1
    fi
}

# Esegui tutte le verifiche della sezione 4

check_os_root_access
check_web_content_access
check_root_override
check_all_directories_override



# 5 Minimize Features, Content and Options
print_section "5 Minimize Features, Content and Options"

# 5.1 Ensure Options for the OS Root Directory Are Restricted
check_root_options() {
    local root_dir_conf=""
    if [ "$DISTRO" = "debian" ]; then
        root_dir_conf=$(grep -r "<Directory /" "$APACHE_PATH" | grep -v "html")
    else
        root_dir_conf=$(grep -r "<Directory /" "$APACHE_PATH" | grep -v "html")
    fi

    if [[ "$root_dir_conf" =~ "Options None" ]] || [[ "$root_dir_conf" =~ "Options -" ]]; then
        print_result "5.1 Options per directory root OS correttamente limitate" 0
    else
        print_result "5.1 Options per directory root OS non limitate correttamente" 1
    fi
}

# 5.2 Ensure Options for the Web Root Directory Are Restricted
check_webroot_options() {
    local doc_root=""
    if [ "$DISTRO" = "debian" ]; then
        doc_root=$(grep -r "DocumentRoot" "$APACHE_PATH/sites-enabled/" | awk '{print $2}' | head -1)
    else
        doc_root=$(grep -r "DocumentRoot" "$APACHE_PATH/conf/httpd.conf" | awk '{print $2}' | head -1)
    fi

    local webroot_conf=""
    if [ -n "$doc_root" ]; then
        webroot_conf=$(grep -r "<Directory $doc_root>" "$APACHE_PATH" -A10)
        if [[ "$webroot_conf" =~ "Options None" ]] || [[ "$webroot_conf" =~ "Options -" ]] ||
           [[ "$webroot_conf" =~ "Options -Indexes -FollowSymLinks" ]]; then
            print_result "5.2 Options per DocumentRoot correttamente limitate" 0
        else
            print_result "5.2 Options per DocumentRoot non limitate correttamente" 1
        fi
    else
        print_result "5.2 DocumentRoot non trovata" 1
    fi
}

# 5.3 Ensure Options for Other Directories Are Minimized
check_other_directories_options() {
    local issues_found=0
    local dir_configs=""

    if [ "$DISTRO" = "debian" ]; then
        dir_configs=$(find "$APACHE_PATH" -type f -exec grep -l "<Directory" {} \;)
    else
        dir_configs=$(find "$APACHE_PATH" -type f -exec grep -l "<Directory" {} \;)
    fi

    for config in $dir_configs; do
        if grep -q "<Directory" "$config"; then
            if ! grep -q "Options None" "$config" && ! grep -q "Options -" "$config"; then
                local dir_entry=$(grep -A5 "<Directory" "$config")
                if [[ "$dir_entry" =~ "Options" ]] && ! [[ "$dir_entry" =~ "Options None" ]] &&
                   ! [[ "$dir_entry" =~ "Options -" ]]; then
                    issues_found=1
                    echo "Directory in $config ha Options non minimizzate"
                fi
            fi
        fi
    done

    if [ $issues_found -eq 0 ]; then
        print_result "5.3 Options minimizzate per tutte le directory" 0
    else
        print_result "5.3 Options non minimizzate per alcune directory" 1
    fi
}

# 5.4 Ensure Default HTML Content Is Removed
check_default_content() {
    local default_files=()
    if [ "$DISTRO" = "debian" ]; then
        default_files+=("/var/www/html/index.html")
        default_files+=("/var/www/html/index.debian.html")
    else
        default_files+=("/var/www/html/index.html")
        default_files+=("/var/www/html/poweredby.png")
    fi

    local default_content_found=0
    for file in "${default_files[@]}"; do
        if [ -f "$file" ]; then
            default_content_found=1
            echo "File di default trovato: $file"
        fi
    done

    if [ $default_content_found -eq 0 ]; then
        print_result "5.4 Nessun contenuto HTML di default trovato" 0
    else
        print_result "5.4 Contenuto HTML di default presente" 1
    fi
}

# Continuo sezione 5

# 5.5 Ensure the Default CGI Content printenv Script Is Removed
check_printenv_script() {
    local cgi_dirs=("/usr/lib/cgi-bin" "/var/www/cgi-bin")
    local script_found=0

    for dir in "${cgi_dirs[@]}"; do
        if [ -f "$dir/printenv" ] || [ -f "$dir/printenv.pl" ]; then
            script_found=1
            echo "Script printenv trovato in: $dir"
        fi
    done

    if [ $script_found -eq 0 ]; then
        print_result "5.5 Script printenv non trovato" 0
    else
        print_result "5.5 Script printenv presente" 1
    fi
}

# 5.6 Ensure the Default CGI Content test-cgi Script Is Removed
check_test_cgi() {
    local cgi_dirs=("/usr/lib/cgi-bin" "/var/www/cgi-bin")
    local script_found=0

    for dir in "${cgi_dirs[@]}"; do
        if [ -f "$dir/test-cgi" ]; then
            script_found=1
            echo "Script test-cgi trovato in: $dir"
        fi
    done

    if [ $script_found -eq 0 ]; then
        print_result "5.6 Script test-cgi non trovato" 0
    else
        print_result "5.6 Script test-cgi presente" 1
    fi
}

# 5.7 Ensure HTTP Request Methods Are Restricted
check_http_methods() {
    local config_files=()
    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
        config_files+=("$APACHE_PATH/conf-enabled/*.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
        config_files+=("$APACHE_PATH/conf.d/*.conf")
    fi

    local method_restriction_found=0
    for conf in "${config_files[@]}"; do
        if grep -q "LimitExcept GET POST HEAD" "$conf" 2>/dev/null; then
            method_restriction_found=1
            break
        fi
    done

    if [ $method_restriction_found -eq 1 ]; then
        print_result "5.7 Metodi HTTP correttamente limitati" 0
    else
        print_result "5.7 Metodi HTTP non limitati" 1
    fi
}

# 5.8 Ensure the HTTP TRACE Method Is Disabled
check_trace_method() {
    local trace_disabled=0
    if [ "$DISTRO" = "debian" ]; then
        if grep -r "TraceEnable Off" "$APACHE_PATH" >/dev/null 2>&1; then
            trace_disabled=1
        fi
    else
        if grep -r "TraceEnable Off" "$APACHE_PATH" >/dev/null 2>&1; then
            trace_disabled=1
        fi
    fi

    if [ $trace_disabled -eq 1 ]; then
        print_result "5.8 Metodo TRACE disabilitato" 0
    else
        print_result "5.8 Metodo TRACE non disabilitato" 1
    fi
}

# 5.9 Ensure Old HTTP Protocol Versions Are Disallowed
check_old_protocols() {
    local protocols_restricted=0
    if [ "$DISTRO" = "debian" ]; then
        if grep -r "Protocols h2 http/1.1" "$APACHE_PATH" >/dev/null 2>&1; then
            protocols_restricted=1
        fi
    else
        if grep -r "Protocols h2 http/1.1" "$APACHE_PATH" >/dev/null 2>&1; then
            protocols_restricted=1
        fi
    fi

    if [ $protocols_restricted -eq 1 ]; then
        print_result "5.9 Versioni vecchie protocollo HTTP disabilitate" 0
    else
        print_result "5.9 Versioni vecchie protocollo HTTP potrebbero essere abilitate" 1
    fi
}

# 5.10 Ensure Access to .ht* Files Is Restricted
check_htaccess_access() {
    local htaccess_protected=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
        config_files+=("$APACHE_PATH/conf-enabled/*.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
        config_files+=("$APACHE_PATH/conf.d/*.conf")
    fi

    for conf in "${config_files[@]}"; do
        if grep -q "<FilesMatch \"^\\.ht\">" "$conf" 2>/dev/null; then
            if grep -q "Require all denied" "$conf" 2>/dev/null; then
                htaccess_protected=1
                break
            fi
        fi
    done

    if [ $htaccess_protected -eq 1 ]; then
        print_result "5.10 Accesso ai file .ht* correttamente limitato" 0
    else
        print_result "5.10 Accesso ai file .ht* non limitato" 1
    fi
}

# 5.11 Ensure Access to .git Files Is Restricted
check_git_access() {
    local git_protected=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
        config_files+=("$APACHE_PATH/conf-enabled/*.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
        config_files+=("$APACHE_PATH/conf.d/*.conf")
    fi

    for conf in "${config_files[@]}"; do
        if grep -q "<DirectoryMatch \"\\.git\">" "$conf" 2>/dev/null; then
            if grep -q "Require all denied" "$conf" 2>/dev/null; then
                git_protected=1
                break
            fi
        fi
    done

    if [ $git_protected -eq 1 ]; then
        print_result "5.11 Accesso ai file .git correttamente limitato" 0
    else
        print_result "5.11 Accesso ai file .git non limitato" 1
    fi
}

# 5.12 Ensure Access to .svn Files Is Restricted
check_svn_access() {
    local svn_protected=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
        config_files+=("$APACHE_PATH/conf-enabled/*.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
        config_files+=("$APACHE_PATH/conf.d/*.conf")
    fi

    for conf in "${config_files[@]}"; do
        if grep -q "<DirectoryMatch \"\\.svn\">" "$conf" 2>/dev/null; then
            if grep -q "Require all denied" "$conf" 2>/dev/null; then
                svn_protected=1
                break
            fi
        fi
    done

    if [ $svn_protected -eq 1 ]; then
        print_result "5.12 Accesso ai file .svn correttamente limitato" 0
    else
        print_result "5.12 Accesso ai file .svn non limitato" 1
    fi
}

# 5.13 Ensure Access to Inappropriate File Extensions Is Restricted
check_inappropriate_extensions() {
    local extensions_protected=0
    local dangerous_extensions=("exe" "dll" "cmd" "pl" "py" "cgi" "sh" "jar" "com" "bat" "php" "asp" "aspx" "tmp")
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
        config_files+=("$APACHE_PATH/conf-enabled/*.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
        config_files+=("$APACHE_PATH/conf.d/*.conf")
    fi

    for conf in "${config_files[@]}"; do
        for ext in "${dangerous_extensions[@]}"; do
            if grep -q "<FilesMatch \"\\.$ext\">" "$conf" 2>/dev/null; then
                if grep -q "Require all denied" "$conf" 2>/dev/null; then
                    extensions_protected=1
                    break 2
                fi
            fi
        done
    done

    if [ $extensions_protected -eq 1 ]; then
        print_result "5.13 Accesso a estensioni inappropriate limitato" 0
    else
        print_result "5.13 Accesso a estensioni inappropriate non limitato" 1
    fi
}

# 5.14 Ensure IP Address Based Requests Are Disallowed
check_ip_requests() {
    local ip_requests_blocked=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
        config_files+=("$APACHE_PATH/conf-enabled/*.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
        config_files+=("$APACHE_PATH/conf.d/*.conf")
    fi

    for conf in "${config_files[@]}"; do
        if grep -q "RewriteCond %{HTTP_HOST} !^[a-zA-Z0-9]" "$conf" 2>/dev/null; then
            if grep -q "RewriteRule .* - [F]" "$conf" 2>/dev/null; then
                ip_requests_blocked=1
                break
            fi
        fi
    done

    if [ $ip_requests_blocked -eq 1 ]; then
        print_result "5.14 Richieste basate su IP bloccate" 0
    else
        print_result "5.14 Richieste basate su IP non bloccate" 1
    fi
}

# 5.15 Ensure the IP Addresses for Listening for Requests Are Specified
check_listen_addresses() {
    local listen_specified=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/ports.conf")
        config_files+=("$APACHE_PATH/conf-enabled/*.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
        config_files+=("$APACHE_PATH/conf.d/*.conf")
    fi

    for conf in "${config_files[@]}"; do
        if grep -q "^Listen [0-9]" "$conf" 2>/dev/null; then
            listen_specified=1
            break
        fi
    done

    if [ $listen_specified -eq 1 ]; then
        print_result "5.15 Indirizzi IP per ascolto specificati" 0
    else
        print_result "5.15 Indirizzi IP per ascolto non specificati" 1
    fi
}

# 5.16 Ensure Browser Framing Is Restricted
check_browser_framing() {
    local frame_options_set=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
        config_files+=("$APACHE_PATH/conf-enabled/*.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
        config_files+=("$APACHE_PATH/conf.d/*.conf")
    fi

    for conf in "${config_files[@]}"; do
        if grep -q "Header always append X-Frame-Options" "$conf" 2>/dev/null; then
            if grep -q "SAMEORIGIN\|DENY" "$conf" 2>/dev/null; then
                frame_options_set=1
                break
            fi
        fi
    done

    if [ $frame_options_set -eq 1 ]; then
        print_result "5.16 Frame Options configurato correttamente" 0
    else
        print_result "5.16 Frame Options non configurato" 1
    fi
}

# 5.17 Ensure HTTP Header Referrer-Policy is set appropriately
check_referrer_policy() {
    local referrer_policy_set=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
        config_files+=("$APACHE_PATH/conf-enabled/*.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
        config_files+=("$APACHE_PATH/conf.d/*.conf")
    fi

    for conf in "${config_files[@]}"; do
        if grep -q "Header always set Referrer-Policy" "$conf" 2>/dev/null; then
            if grep -q "no-referrer\|same-origin\|strict-origin" "$conf" 2>/dev/null; then
                referrer_policy_set=1
                break
            fi
        fi
    done

    if [ $referrer_policy_set -eq 1 ]; then
        print_result "5.17 Referrer-Policy configurato correttamente" 0
    else
        print_result "5.17 Referrer-Policy non configurato" 1
    fi
}

# 5.18 Ensure HTTP Header Permissions-Policy is set appropriately
check_permissions_policy() {
    local permissions_policy_set=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
        config_files+=("$APACHE_PATH/conf-enabled/*.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
        config_files+=("$APACHE_PATH/conf.d/*.conf")
    fi

    for conf in "${config_files[@]}"; do
        if grep -q "Header always set Permissions-Policy" "$conf" 2>/dev/null; then
            permissions_policy_set=1
            break
        fi
    done

    if [ $permissions_policy_set -eq 1 ]; then
        print_result "5.18 Permissions-Policy configurato" 0
    else
        print_result "5.18 Permissions-Policy non configurato" 1
    fi
}

# Esegui le verifiche della sezione 5
check_root_options
#check_webroot_options
#check_other_directories_options
#check_default_content
#check_printenv_script
#check_test_cgi
check_http_methods
check_trace_method
check_old_protocols
check_htaccess_access
#check_git_access
#check_svn_access
check_inappropriate_extensions
check_ip_requests
check_listen_addresses
#check_browser_framing
#check_referrer_policy
#check_permissions_policy


# 6 Operations - Logging, Monitoring and Maintenance
print_section "6 Operations - Logging, Monitoring and Maintenance"

# 6.1 Ensure the Error Log Filename and Severity Level Are Configured Correctly
check_error_log_config() {
    local error_log_configured=0
    local severity_configured=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
        config_files+=("$APACHE_PATH/conf-enabled/*.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
        config_files+=("$APACHE_PATH/conf.d/*.conf")
    fi

    for conf in "${config_files[@]}"; do
        # Verifica ErrorLog
        if grep -q "^ErrorLog" "$conf" 2>/dev/null; then
            error_log_configured=1
        fi

        # Verifica LogLevel
        if grep -q "^LogLevel warn\|^LogLevel error" "$conf" 2>/dev/null; then
            severity_configured=1
        fi
    done

    if [ $error_log_configured -eq 1 ] && [ $severity_configured -eq 1 ]; then
        print_result "6.1 Error Log configurato correttamente" 0
    else
        print_result "6.1 Error Log non configurato correttamente" 1
    fi
}

# 6.2 Ensure a Syslog Facility Is Configured for Error Logging
check_syslog_facility() {
    local syslog_configured=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
        config_files+=("$APACHE_PATH/conf-enabled/*.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
        config_files+=("$APACHE_PATH/conf.d/*.conf")
    fi

    for conf in "${config_files[@]}"; do
        if grep -q "ErrorLog syslog:" "$conf" 2>/dev/null; then
            syslog_configured=1
            break
        fi
    done

    if [ $syslog_configured -eq 1 ]; then
        print_result "6.2 Syslog facility configurata" 0
    else
        print_result "6.2 Syslog facility non configurata" 1
    fi
}

# 6.3 Ensure the Server Access Log Is Configured Correctly
check_access_log_config() {
    local access_log_configured=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
        config_files+=("$APACHE_PATH/conf-enabled/*.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
        config_files+=("$APACHE_PATH/conf.d/*.conf")
    fi

    for conf in "${config_files[@]}"; do
        if grep -q "^CustomLog" "$conf" 2>/dev/null; then
            if grep -q "combined" "$conf" 2>/dev/null; then
                access_log_configured=1
                break
            fi
        fi
    done

    if [ $access_log_configured -eq 1 ]; then
        print_result "6.3 Access Log configurato correttamente" 0
    else
        print_result "6.3 Access Log non configurato correttamente" 1
    fi
}

# 6.4 Ensure Log Storage and Rotation Is Configured Correctly
check_log_rotation_config() {
    local logrotate_conf=""
    if [ "$DISTRO" = "debian" ]; then
        logrotate_conf="/etc/logrotate.d/apache2"
    else
        logrotate_conf="/etc/logrotate.d/httpd"
    fi

    if [ -f "$logrotate_conf" ]; then
        # Verifica rotazione
        if grep -q "rotate" "$logrotate_conf" && grep -q "weekly\|daily" "$logrotate_conf"; then
            print_result "6.4 Log rotation configurata correttamente" 0
        else
            print_result "6.4 Log rotation non configurata correttamente" 1
        fi
    else
        print_result "6.4 File configurazione logrotate non trovato" 1
    fi
}

# 6.5 Ensure Applicable Patches Are Applied
check_apache_version() {
    local apache_version=""
    if [ "$DISTRO" = "debian" ]; then
        apache_version=$($APACHE_CTL -v | grep "Server version")
    else
        apache_version=$($APACHE_CTL -v | grep "Server version")
    fi

    echo -e "${YELLOW}6.5 Versione Apache:${NC}"
    echo "$apache_version"
    echo "Verificare manualmente gli aggiornamenti disponibili"
}

# 6.6 Ensure ModSecurity Is Installed and Enabled
check_modsecurity() {
    local modsec_installed=0

    if [ "$DISTRO" = "debian" ]; then
        if apache2ctl -M 2>/dev/null | grep -q "security2_module"; then
            modsec_installed=1
        fi
    else
        if httpd -M 2>/dev/null | grep -q "security2_module"; then
            modsec_installed=1
        fi
    fi

    if [ $modsec_installed -eq 1 ]; then
        print_result "6.6 ModSecurity installato e abilitato" 0
    else
        print_result "6.6 ModSecurity non installato o non abilitato" 1
    fi
}

# 6.7 Ensure the OWASP ModSecurity Core Rule Set Is Installed and Enabled
check_owasp_crs() {
    local crs_installed=0
    local crs_paths=("/usr/share/modsecurity-crs" "/etc/apache2/modsecurity.d/owasp-crs" "/etc/httpd/modsecurity.d/owasp-crs")

    for path in "${crs_paths[@]}"; do
        if [ -d "$path" ]; then
            if [ -f "$path/crs-setup.conf" ]; then
                crs_installed=1
                break
            fi
        fi
    done

    if [ $crs_installed -eq 1 ]; then
        print_result "6.7 OWASP ModSecurity CRS installato" 0
    else
        print_result "6.7 OWASP ModSecurity CRS non installato" 1
    fi
}

# Esegui le verifiche della sezione 6

check_error_log_config
check_syslog_facility
check_access_log_config
check_log_rotation_config
check_apache_version
#check_modsecurity
#check_owasp_crs

# 7 SSL/TLS Configuration
print_section "7 SSL/TLS Configuration"

# 7.1 Ensure mod_ssl and/or mod_nss Is Installed
check_ssl_modules() {
    local ssl_installed=0

    if [ "$DISTRO" = "debian" ]; then
        if apache2ctl -M 2>/dev/null | grep -q "ssl_module\|nss_module"; then
            ssl_installed=1
        fi
    else
        if httpd -M 2>/dev/null | grep -q "ssl_module\|nss_module"; then
            ssl_installed=1
        fi
    fi

    if [ $ssl_installed -eq 1 ]; then
        print_result "7.1 mod_ssl o mod_nss installato" 0
    else
        print_result "7.1 mod_ssl o mod_nss non installato" 1
    fi
}

# 7.2 Ensure a Valid Trusted Certificate Is Installed
check_ssl_certificate() {
    local cert_valid=0
    local ssl_conf=""
    local cert_file=""

    if [ "$DISTRO" = "debian" ]; then
        ssl_conf="$APACHE_PATH/sites-enabled/default-ssl.conf"
    else
        ssl_conf="$APACHE_PATH/conf.d/ssl.conf"
    fi

    if [ -f "$ssl_conf" ]; then
        cert_file=$(grep "^[[:space:]]*SSLCertificateFile" "$ssl_conf" | awk '{print $2}')
        if [ -f "$cert_file" ]; then
            # Verifica validità certificato
            if openssl x509 -in "$cert_file" -noout -checkend 0 >/dev/null 2>&1; then
                cert_valid=1
            fi
        fi
    fi

    if [ $cert_valid -eq 1 ]; then
        print_result "7.2 Certificato SSL valido installato" 0
    else
        print_result "7.2 Certificato SSL non valido o non trovato" 1
    fi
}

# 7.3 Ensure the Server's Private Key Is Protected
check_private_key_protection() {
    local key_protected=0
    local ssl_conf=""
    local key_file=""

    if [ "$DISTRO" = "debian" ]; then
        ssl_conf="$APACHE_PATH/sites-enabled/default-ssl.conf"
    else
        ssl_conf="$APACHE_PATH/conf.d/ssl.conf"
    fi

    if [ -f "$ssl_conf" ]; then
        key_file=$(grep "^[[:space:]]*SSLCertificateKeyFile" "$ssl_conf" | awk '{print $2}')
        if [ -f "$key_file" ]; then
            local key_perms=$(stat -c %a "$key_file")
            local key_owner=$(stat -c %U "$key_file")
            if [ "$key_perms" = "400" ] && [ "$key_owner" = "root" ]; then
                key_protected=1
            fi
        fi
    fi

    if [ $key_protected -eq 1 ]; then
        print_result "7.3 Chiave privata protetta correttamente" 0
    else
        print_result "7.3 Chiave privata non protetta correttamente" 1
    fi
}

# 7.4 Ensure the TLSv1.0 and TLSv1.1 Protocols are Disabled
check_tls_version() {
    local tls_secure=0
    local ssl_conf=""

    if [ "$DISTRO" = "debian" ]; then
        ssl_conf="$APACHE_PATH/mods-enabled/ssl.conf"
    else
        ssl_conf="$APACHE_PATH/conf.d/ssl.conf"
    fi

    if [ -f "$ssl_conf" ]; then
        if grep -q "^[[:space:]]*SSLProtocol" "$ssl_conf"; then
            if ! grep -q "TLSv1\.0\|TLSv1\.1" "$ssl_conf" && grep -q "TLSv1\.2\|TLSv1\.3" "$ssl_conf"; then
                tls_secure=1
            fi
        fi
    fi

    if [ $tls_secure -eq 1 ]; then
        print_result "7.4 TLSv1.0 e TLSv1.1 disabilitati" 0
    else
        print_result "7.4 TLSv1.0 o TLSv1.1 potrebbero essere abilitati" 1
    fi
}

# 7.5 Ensure Weak SSL/TLS Ciphers Are Disabled
check_weak_ciphers() {
    local strong_ciphers=0
    local ssl_conf=""

    if [ "$DISTRO" = "debian" ]; then
        ssl_conf="$APACHE_PATH/mods-enabled/ssl.conf"
    else
        ssl_conf="$APACHE_PATH/conf.d/ssl.conf"
    fi

    if [ -f "$ssl_conf" ]; then
        if grep -q "^[[:space:]]*SSLCipherSuite" "$ssl_conf"; then
            if ! grep -q "RC4\|DES\|MD5\|EXP\|ADH\|NULL" "$ssl_conf"; then
                strong_ciphers=1
            fi
        fi
    fi

    if [ $strong_ciphers -eq 1 ]; then
        print_result "7.5 Cipher suite configurata in modo sicuro" 0
    else
        print_result "7.5 Possibili cipher deboli abilitati" 1
    fi
}

# 7.6 Ensure Insecure SSL Renegotiation Is Not Enabled
check_ssl_renegotiation() {
    local secure_reneg=0
    local ssl_conf=""

    if [ "$DISTRO" = "debian" ]; then
        ssl_conf="$APACHE_PATH/mods-enabled/ssl.conf"
    else
        ssl_conf="$APACHE_PATH/conf.d/ssl.conf"
    fi

    if [ -f "$ssl_conf" ]; then
        if ! grep -q "SSLInsecureRenegotiation on" "$ssl_conf"; then
            secure_reneg=1
        fi
    fi

    if [ $secure_reneg -eq 1 ]; then
        print_result "7.6 Rinegoziazione SSL sicura" 0
    else
        print_result "7.6 Rinegoziazione SSL insicura potrebbe essere abilitata" 1
    fi
}

# 7.7 Ensure SSL Compression is not Enabled
check_ssl_compression() {
    local compression_disabled=0
    local ssl_conf=""

    if [ "$DISTRO" = "debian" ]; then
        ssl_conf="$APACHE_PATH/mods-enabled/ssl.conf"
    else
        ssl_conf="$APACHE_PATH/conf.d/ssl.conf"
    fi

    if [ -f "$ssl_conf" ]; then
        if grep -q "SSLCompression off" "$ssl_conf"; then
            compression_disabled=1
        fi
    fi

    if [ $compression_disabled -eq 1 ]; then
        print_result "7.7 Compressione SSL disabilitata" 0
    else
        print_result "7.7 Compressione SSL potrebbe essere abilitata" 1
    fi
}

# 7.8 Ensure Medium Strength SSL/TLS Ciphers Are Disabled
check_medium_ciphers() {
    local secure_ciphers=0
    local ssl_conf=""

    if [ "$DISTRO" = "debian" ]; then
        ssl_conf="$APACHE_PATH/mods-enabled/ssl.conf"
    else
        ssl_conf="$APACHE_PATH/conf.d/ssl.conf"
    fi

    if [ -f "$ssl_conf" ]; then
        if grep -q "^[[:space:]]*SSLCipherSuite" "$ssl_conf"; then
            if ! grep -q "!3DES\|!IDEA\|!SEED\|!CAMELLIA" "$ssl_conf"; then
                secure_ciphers=1
            fi
        fi
    fi

    if [ $secure_ciphers -eq 1 ]; then
        print_result "7.8 Cipher di media forza disabilitati" 0
    else
        print_result "7.8 Cipher di media forza potrebbero essere abilitati" 1
    fi
}

# 7.9 Ensure All Web Content is Accessed via HTTPS
check_https_only() {
    local https_enforced=0
    local vhost_files=()

    if [ "$DISTRO" = "debian" ]; then
        vhost_files+=("$APACHE_PATH/sites-enabled/*")
    else
        vhost_files+=("$APACHE_PATH/conf.d/*.conf")
    fi

    for conf in "${vhost_files[@]}"; do
        if [ -f "$conf" ]; then
            if grep -q "RewriteEngine On" "$conf" && grep -q "RewriteCond.*HTTPS off" "$conf" && grep -q "RewriteRule.*https://" "$conf"; then
                https_enforced=1
                break
            fi
        fi
    done

    if [ $https_enforced -eq 1 ]; then
        print_result "7.9 Reindirizzamento HTTPS configurato" 0
    else
        print_result "7.9 Reindirizzamento HTTPS non configurato" 1
    fi
}

# 7.10 Ensure OCSP Stapling Is Enabled
check_ocsp_stapling() {
    local stapling_enabled=0
    local ssl_conf=""

    if [ "$DISTRO" = "debian" ]; then
        ssl_conf="$APACHE_PATH/mods-enabled/ssl.conf"
    else
        ssl_conf="$APACHE_PATH/conf.d/ssl.conf"
    fi

    if [ -f "$ssl_conf" ]; then
        if grep -q "SSLUseStapling on" "$ssl_conf" && grep -q "SSLStaplingCache" "$ssl_conf"; then
            stapling_enabled=1
        fi
    fi

    if [ $stapling_enabled -eq 1 ]; then
        print_result "7.10 OCSP Stapling abilitato" 0
    else
        print_result "7.10 OCSP Stapling non abilitato" 1
    fi
}

# 7.11 Ensure HTTP Strict Transport Security Is Enabled
check_hsts() {
    local hsts_enabled=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/conf-enabled/*.conf")
    else
        config_files+=("$APACHE_PATH/conf.d/*.conf")
    fi

    for conf in "${config_files[@]}"; do
        if grep -q "Header always set Strict-Transport-Security" "$conf"; then
            hsts_enabled=1
            break
        fi
    done

    if [ $hsts_enabled -eq 1 ]; then
        print_result "7.11 HSTS abilitato" 0
    else
        print_result "7.11 HSTS non abilitato" 1
    fi
}

# 7.12 Ensure Only Cipher Suites That Provide Forward Secrecy Are Enabled
check_forward_secrecy() {
    local forward_secrecy=0
    local ssl_conf=""

    if [ "$DISTRO" = "debian" ]; then
        ssl_conf="$APACHE_PATH/mods-enabled/ssl.conf"
    else
        ssl_conf="$APACHE_PATH/conf.d/ssl.conf"
    fi

    if [ -f "$ssl_conf" ]; then
        if grep -q "^[[:space:]]*SSLCipherSuite.*EECDH\|EDH" "$ssl_conf"; then
            forward_secrecy=1
        fi
    fi

    if [ $forward_secrecy -eq 1 ]; then
        print_result "7.12 Forward Secrecy abilitato" 0
    else
        print_result "7.12 Forward Secrecy non abilitato" 1
    fi
}

# Esegui tutte le verifiche della sezione 7
check_ssl_modules
check_ssl_certificate
check_private_key_protection
check_tls_version
check_weak_ciphers
check_ssl_renegotiation
#check_ssl_compression
check_medium_ciphers
#check_https_only
check_ocsp_stapling
check_hsts
check_forward_secrecy


# 8 Information Leakage
print_section "8 Information Leakage"

# 8.1 Ensure ServerTokens is Set to 'Prod' or 'ProductOnly'
check_server_tokens() {
    local tokens_secure=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/conf-enabled/security.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
    fi

    for conf in "${config_files[@]}"; do
        if [ -f "$conf" ] && grep -q "^ServerTokens[[:space:]]\+\(Prod\|ProductOnly\)" "$conf"; then
            tokens_secure=1
            break
        fi
    done

    if [ $tokens_secure -eq 1 ]; then
        print_result "8.1 ServerTokens impostato correttamente" 0
    else
        print_result "8.1 ServerTokens non impostato correttamente" 1
    fi
}

# 8.2 Ensure ServerSignature Is Not Enabled
check_server_signature() {
    local signature_disabled=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/conf-enabled/security.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
    fi

    for conf in "${config_files[@]}"; do
        if [ -f "$conf" ] && grep -q "^ServerSignature[[:space:]]\+Off" "$conf"; then
            signature_disabled=1
            break
        fi
    done

    if [ $signature_disabled -eq 1 ]; then
        print_result "8.2 ServerSignature disabilitato" 0
    else
        print_result "8.2 ServerSignature non disabilitato" 1
    fi
}

# 8.3 Ensure All Default Apache Content Is Removed
check_default_content() {
    local default_content_found=0
    local default_files=(
        "manual" "manual.html" "icons" "error" "welcome.conf"
        "README" "htdocs" "cgi-bin" "test" "example" "sample"
    )

    for file in "${default_files[@]}"; do
        if [ -e "$APACHE_PATH/$file" ] || [ -e "/var/www/html/$file" ]; then
            default_content_found=1
            echo "Contenuto di default trovato: $file"
        fi
    done

    if [ $default_content_found -eq 0 ]; then
        print_result "8.3 Nessun contenuto di default trovato" 0
    else
        print_result "8.3 Contenuto di default presente" 1
    fi
}

# 8.4 Ensure ETag Response Header Fields Do Not Include Inodes
check_etag_headers() {
    local etag_secure=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/conf-enabled/")
    else
        config_files+=("$APACHE_PATH/conf/")
    fi

    for conf in "${config_files[@]}"; do
        if [ -f "$conf" ] && grep -q "^FileETag" "$conf"; then
            if ! grep -q "^FileETag.*INode" "$conf"; then
                etag_secure=1
                break
            fi
        fi
    done

    if [ $etag_secure -eq 1 ]; then
        print_result "8.4 ETag configurato in modo sicuro" 0
    else
        print_result "8.4 ETag potrebbe includere Inodes" 1
    fi
}

# Esegui tutte le verifiche della sezione 8
check_server_tokens
check_server_signature
check_default_content
check_etag_headers

# 9 Denial of Service Mitigations
print_section "9 Denial of Service Mitigations"

# 9.1 Ensure the TimeOut Is Set to 10 or Less
check_timeout() {
    local timeout_secure=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
    fi

    for conf in "${config_files[@]}"; do
        if [ -f "$conf" ]; then
            local timeout_value=$(grep "^Timeout" "$conf" | awk '{print $2}')
            if [ -n "$timeout_value" ] && [ "$timeout_value" -le 10 ]; then
                timeout_secure=1
                break
            fi
        fi
    done

    if [ $timeout_secure -eq 1 ]; then
        print_result "9.1 Timeout configurato correttamente (≤10)" 0
    else
        print_result "9.1 Timeout non configurato correttamente" 1
    fi
}

# 9.2 Ensure KeepAlive Is Enabled
check_keepalive() {
    local keepalive_enabled=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
    fi

    for conf in "${config_files[@]}"; do
        if [ -f "$conf" ] && grep -q "^KeepAlive[[:space:]]\+On" "$conf"; then
            keepalive_enabled=1
            break
        fi
    done

    if [ $keepalive_enabled -eq 1 ]; then
        print_result "9.2 KeepAlive abilitato" 0
    else
        print_result "9.2 KeepAlive non abilitato" 1
    fi
}

# 9.3 Ensure MaxKeepAliveRequests is Set to 100 or Greater
check_max_keepalive_requests() {
    local max_keepalive_secure=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
    fi

    for conf in "${config_files[@]}"; do
        if [ -f "$conf" ]; then
            local max_value=$(grep "^MaxKeepAliveRequests" "$conf" | awk '{print $2}')
            if [ -n "$max_value" ] && [ "$max_value" -ge 100 ]; then
                max_keepalive_secure=1
                break
            fi
        fi
    done

    if [ $max_keepalive_secure -eq 1 ]; then
        print_result "9.3 MaxKeepAliveRequests configurato correttamente (≥100)" 0
    else
        print_result "9.3 MaxKeepAliveRequests non configurato correttamente" 1
    fi
}

# 9.4 Ensure KeepAliveTimeout is Set to 15 or Less
check_keepalive_timeout() {
    local keepalive_timeout_secure=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
    fi

    for conf in "${config_files[@]}"; do
        if [ -f "$conf" ]; then
            local timeout_value=$(grep "^KeepAliveTimeout" "$conf" | awk '{print $2}')
            if [ -n "$timeout_value" ] && [ "$timeout_value" -le 15 ]; then
                keepalive_timeout_secure=1
                break
            fi
        fi
    done

    if [ $keepalive_timeout_secure -eq 1 ]; then
        print_result "9.4 KeepAliveTimeout configurato correttamente (≤15)" 0
    else
        print_result "9.4 KeepAliveTimeout non configurato correttamente" 1
    fi
}

# 9.5 Ensure the Timeout Limits for Request Headers is Set to 40 or Less
check_request_headers_timeout() {
    local headers_timeout_secure=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
    fi

    for conf in "${config_files[@]}"; do
        if [ -f "$conf" ]; then
            local timeout_value=$(grep "^RequestReadTimeout[[:space:]]\+header=" "$conf" | grep -o "header=[0-9]*" | cut -d= -f2)
            if [ -n "$timeout_value" ] && [ "$timeout_value" -le 40 ]; then
                headers_timeout_secure=1
                break
            fi
        fi
    done

    if [ $headers_timeout_secure -eq 1 ]; then
        print_result "9.5 Request Headers Timeout configurato correttamente (≤40)" 0
    else
        print_result "9.5 Request Headers Timeout non configurato correttamente" 1
    fi
}

# 9.6 Ensure Timeout Limits for the Request Body is Set to 20 or Less
check_request_body_timeout() {
    local body_timeout_secure=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
    fi

    for conf in "${config_files[@]}"; do
        if [ -f "$conf" ]; then
            local timeout_value=$(grep "^RequestReadTimeout[[:space:]]\+body=" "$conf" | grep -o "body=[0-9]*" | cut -d= -f2)
            if [ -n "$timeout_value" ] && [ "$timeout_value" -le 20 ]; then
                body_timeout_secure=1
                break
            fi
        fi
    done

    if [ $body_timeout_secure -eq 1 ]; then
        print_result "9.6 Request Body Timeout configurato correttamente (≤20)" 0
    else
        print_result "9.6 Request Body Timeout non configurato correttamente" 1
    fi
}

# Esegui tutte le verifiche della sezione 9

check_timeout
check_keepalive
check_max_keepalive_requests
check_keepalive_timeout
check_request_headers_timeout
check_request_body_timeout

# 10 Request Limits
print_section "10 Request Limits"

# 10.1 Ensure the LimitRequestLine directive is Set to 512 or less
check_limit_request_line() {
    local request_line_secure=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
    fi

    for conf in "${config_files[@]}"; do
        if [ -f "$conf" ]; then
            local limit_value=$(grep "^LimitRequestLine" "$conf" | awk '{print $2}')
            if [ -n "$limit_value" ] && [ "$limit_value" -le 512 ]; then
                request_line_secure=1
                break
            fi
        fi
    done

    if [ $request_line_secure -eq 1 ]; then
        print_result "10.1 LimitRequestLine configurato correttamente (≤512)" 0
    else
        print_result "10.1 LimitRequestLine non configurato correttamente" 1
    fi
}

# 10.2 Ensure the LimitRequestFields Directive is Set to 100 or Less
check_limit_request_fields() {
    local request_fields_secure=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
    fi

    for conf in "${config_files[@]}"; do
        if [ -f "$conf" ]; then
            local limit_value=$(grep "^LimitRequestFields" "$conf" | awk '{print $2}')
            if [ -n "$limit_value" ] && [ "$limit_value" -le 100 ]; then
                request_fields_secure=1
                break
            fi
        fi
    done

    if [ $request_fields_secure -eq 1 ]; then
        print_result "10.2 LimitRequestFields configurato correttamente (≤100)" 0
    else
        print_result "10.2 LimitRequestFields non configurato correttamente" 1
    fi
}

# 10.3 Ensure the LimitRequestFieldsize Directive is Set to 1024 or Less
check_limit_request_fieldsize() {
    local request_fieldsize_secure=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
    fi

    for conf in "${config_files[@]}"; do
        if [ -f "$conf" ]; then
            local limit_value=$(grep "^LimitRequestFieldSize" "$conf" | awk '{print $2}')
            if [ -n "$limit_value" ] && [ "$limit_value" -le 1024 ]; then
                request_fieldsize_secure=1
                break
            fi
        fi
    done

    if [ $request_fieldsize_secure -eq 1 ]; then
        print_result "10.3 LimitRequestFieldSize configurato correttamente (≤1024)" 0
    else
        print_result "10.3 LimitRequestFieldSize non configurato correttamente" 1
    fi
}

# 10.4 Ensure the LimitRequestBody Directive is Set to 102400 or Less
check_limit_request_body() {
    local request_body_secure=0
    local config_files=()

    if [ "$DISTRO" = "debian" ]; then
        config_files+=("$APACHE_PATH/apache2.conf")
    else
        config_files+=("$APACHE_PATH/conf/httpd.conf")
    fi

    for conf in "${config_files[@]}"; do
        if [ -f "$conf" ]; then
            local limit_value=$(grep "^LimitRequestBody" "$conf" | awk '{print $2}')
            if [ -n "$limit_value" ] && [ "$limit_value" -le 102400 ]; then
                request_body_secure=1
                break
            fi
        fi
    done

    if [ $request_body_secure -eq 1 ]; then
        print_result "10.4 LimitRequestBody configurato correttamente (≤102400)" 0
    else
        print_result "10.4 LimitRequestBody non configurato correttamente" 1
    fi
}

# Esegui tutte le verifiche della sezione 10
check_limit_request_line
check_limit_request_fields
check_limit_request_fieldsize
check_limit_request_body

# 11 Enable SELinux to Restrict Apache Processes
print_section "11 SELinux Configuration"

# 11.1 Ensure SELinux Is Enabled in Enforcing Mode
check_selinux_enforcing() {
    if command -v getenforce >/dev/null 2>&1; then
        local selinux_mode=$(getenforce)
        if [ "$selinux_mode" = "Enforcing" ]; then
            print_result "11.1 SELinux è in modalità Enforcing" 0
        else
            print_result "11.1 SELinux non è in modalità Enforcing ($selinux_mode)" 1
        fi
    else
        print_result "11.1 SELinux non installato" 1
    fi
}

# 11.2 Ensure Apache Processes Run in the httpd_t Confined Context
check_httpd_context() {
    if command -v ps >/dev/null 2>&1 && command -v grep >/dev/null 2>&1; then
        local httpd_context=$(ps axZ | grep httpd | grep -v grep)
        if echo "$httpd_context" | grep -q "httpd_t"; then
            print_result "11.2 Processi Apache in esecuzione nel contesto httpd_t" 0
        else
            print_result "11.2 Processi Apache non in esecuzione nel contesto httpd_t" 1
        fi
    else
        print_result "11.2 Impossibile verificare il contesto SELinux" 1
    fi
}

# 11.3 Ensure the httpd_t Type is Not in Permissive Mode
check_httpd_permissive() {
    if command -v semanage >/dev/null 2>&1; then
        if semanage permissive -l | grep -q "httpd_t"; then
            print_result "11.3 httpd_t è in modalità permissiva" 1
        else
            print_result "11.3 httpd_t non è in modalità permissiva" 0
        fi
    else
        print_result "11.3 Impossibile verificare la modalità permissiva di httpd_t" 1
    fi
}

# 11.4 Ensure Only the Necessary SELinux Booleans are Enabled
check_selinux_booleans() {
    local unnecessary_booleans=(
        "httpd_builtin_scripting"
        "httpd_enable_homedirs"
        "httpd_can_network_connect_db"
        "httpd_can_network_connect"
        "httpd_can_sendmail"
        "httpd_use_cifs"
        "httpd_use_nfs"
    )

    if command -v getsebool >/dev/null 2>&1; then
        local issues_found=0
        for boolean in "${unnecessary_booleans[@]}"; do
            if getsebool -a | grep -q "^$boolean --> on"; then
                issues_found=1
                echo "Boolean non necessario abilitato: $boolean"
            fi
        done

        if [ $issues_found -eq 0 ]; then
            print_result "11.4 Nessun boolean SELinux non necessario abilitato" 0
        else
            print_result "11.4 Boolean SELinux non necessari abilitati" 1
        fi
    else
        print_result "11.4 Impossibile verificare i boolean SELinux" 1
    fi
}

# Esegui tutte le verifiche della sezione 11

#check_selinux_enforcing
#check_httpd_context
#check_httpd_permissive
#check_selinux_booleans

# 12 Enable AppArmor to Restrict Apache Processes
print_section "12 AppArmor Configuration"

# 12.1 Ensure the AppArmor Framework Is Enabled
check_apparmor_enabled() {
    if command -v aa-status >/dev/null 2>&1; then
        if aa-status --enabled 2>/dev/null; then
            print_result "12.1 AppArmor è abilitato" 0
        else
            print_result "12.1 AppArmor non è abilitato" 1
        fi
    else
        print_result "12.1 AppArmor non installato" 1
    fi
}

# 12.2 Ensure the Apache AppArmor Profile Is Configured Properly
check_apache_apparmor_profile() {
    local apache_profile=""
    if [ "$DISTRO" = "debian" ]; then
        apache_profile="/etc/apparmor.d/usr.sbin.apache2"
    else
        apache_profile="/etc/apparmor.d/usr.sbin.httpd"
    fi

    if [ -f "$apache_profile" ]; then
        # Verifica le principali regole del profilo
        local issues_found=0

        # Verifica permessi di lettura per configurazioni
        if ! grep -q "r.* /etc/apache2/\*\*" "$apache_profile" 2>/dev/null; then
            issues_found=1
            echo "Mancano i permessi di lettura per le configurazioni"
        fi

        # Verifica permessi di lettura per i log
        if ! grep -q "r.* /var/log/apache2/\*\*" "$apache_profile" 2>/dev/null; then
            issues_found=1
            echo "Mancano i permessi di lettura per i log"
        fi

        if [ $issues_found -eq 0 ]; then
            print_result "12.2 Profilo AppArmor di Apache configurato correttamente" 0
        else
            print_result "12.2 Profilo AppArmor di Apache non configurato correttamente" 1
        fi
    else
        print_result "12.2 Profilo AppArmor di Apache non trovato" 1
    fi
}

# 12.3 Ensure Apache AppArmor Profile is in Enforce Mode
check_apache_apparmor_enforce() {
    if command -v aa-status >/dev/null 2>&1; then
        local apache_process=""
        if [ "$DISTRO" = "debian" ]; then
            apache_process="apache2"
        else
            apache_process="httpd"
        fi

        if aa-status | grep -q "^$apache_process (enforce)"; then
            print_result "12.3 Profilo AppArmor di Apache in modalità enforce" 0
        else
            print_result "12.3 Profilo AppArmor di Apache non in modalità enforce" 1
        fi
    else
        print_result "12.3 AppArmor non installato" 1
    fi
}

# Esegui tutte le verifiche della sezione 12

#check_apparmor_enabled
#check_apache_apparmor_profile
#check_apache_apparmor_enforce


# Funzione per generare il report finale

# Genera report in formato HTML dettagliato
generate_html_report() {
    local report_file="apache_security_audit_$(date +%Y%m%d_%H%M%S).html"
    local pass_percentage=$((PASSED_CHECKS * 100 / TOTAL_CHECKS))

    cat << EOF > "$report_file"
<!DOCTYPE html>
<html lang="it">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Report Audit Sicurezza Apache CIS</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            line-height: 1.6;
            margin: 0;
            padding: 20px;
            color: #333;
        }
        .container {
            max-width: 1200px;
            margin: 0 auto;
        }
        .header {
            background: #f4f4f4;
            padding: 20px;
            border-radius: 5px;
            margin-bottom: 20px;
        }
        .summary {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 20px;
            margin-bottom: 30px;
        }
        .stat-box {
            background: #fff;
            padding: 20px;
            border-radius: 5px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
            text-align: center;
        }
        .pass { color: #28a745; }
        .fail { color: #dc3545; }
        .warning { color: #ffc107; }
        .section {
            background: #fff;
            padding: 20px;
            border-radius: 5px;
            margin-bottom: 20px;
            box-shadow: 0 2px 5px rgba(0,0,0,0.1);
        }
        .progress-bar {
            width: 100%;
            height: 20px;
            background: #f0f0f0;
            border-radius: 10px;
            margin: 20px 0;
            overflow: hidden;
        }
        .progress {
            height: 100%;
            background: #28a745;
            width: ${pass_percentage}%;
            transition: width 1s ease-in-out;
        }
        table {
            width: 100%;
            border-collapse: collapse;
            margin: 20px 0;
        }
        th, td {
            padding: 12px;
            text-align: left;
            border: 1px solid #ddd;
        }
        th {
            background: #f4f4f4;
        }
        tr:nth-child(even) {
            background: #f9f9f9;
        }
        .remediation {
            background: #e8f4f8;
            padding: 15px;
            border-left: 5px solid #4a90e2;
            margin: 10px 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>Report Audit Sicurezza Apache CIS</h1>
            <p>Data: $(date)</p>
            <p>Sistema: $(uname -a)</p>
            <p>Distribuzione: $DISTRO</p>
            <p>Versione Apache: $($APACHE_CTL -v 2>/dev/null | head -n1)</p>
        </div>

        <div class="summary">
            <div class="stat-box">
                <h3>Totale Controlli</h3>
                <p style="font-size: 24px;">$TOTAL_CHECKS</p>
            </div>
            <div class="stat-box">
                <h3>Controlli Superati</h3>
                <p style="font-size: 24px;" class="pass">$PASSED_CHECKS</p>
            </div>
            <div class="stat-box">
                <h3>Controlli Falliti</h3>
                <p style="font-size: 24px;" class="fail">$FAILED_CHECKS</p>
            </div>
            <div class="stat-box">
                <h3>Percentuale Successo</h3>
                <p style="font-size: 24px;">$pass_percentage%</p>
            </div>
        </div>

        <div class="progress-bar">
            <div class="progress"></div>
        </div>

        <div class="section">
            <h2>Problemi Riscontrati</h2>
            <table>
                <tr>
                    <th>Controllo</th>
                    <th>Stato</th>
                    <th>Dettagli</th>
                </tr>
EOF

    # Aggiungi ogni problema riscontrato alla tabella
    echo "$ISSUES_FOUND" | while IFS= read -r line; do
        if [ -n "$line" ]; then
            cat << EOF >> "$report_file"
                <tr>
                    <td>${line#❌ }</td>
                    <td class="fail">Non Conforme</td>
                    <td>Richiede attenzione</td>
                </tr>
EOF
        fi
    done

    cat << EOF >> "$report_file"
            </table>
        </div>

        <div class="section">
            <h2>Suggerimenti per la Correzione</h2>
EOF

    # Aggiungi i suggerimenti per la correzione
    echo "$REMEDIATION_SUGGESTIONS" | while IFS= read -r line; do
        if [ -n "$line" ]; then
            cat << EOF >> "$report_file"
            <div class="remediation">
                <p>${line#🔧 }</p>
            </div>
EOF
        fi
    done

    cat << EOF >> "$report_file"
        </div>

        <div class="section">
            <h2>Riepilogo per Sezione</h2>
            <table>
                <tr>
                    <th>Sezione</th>
                    <th>Stato</th>
                    <th>Note</th>
                </tr>
                <tr>
                    <td>1. Planning and Installation</td>
                    <td>$([ $section1_issues -eq 0 ] && echo "<span class='pass'>✓</span>" || echo "<span class='fail'>✗</span>")</td>
                    <td>$([ $section1_issues -eq 0 ] && echo "Conforme" || echo "Richiede attenzione")</td>
                </tr>
                <tr>
                    <td>2. Apache Modules</td>
                    <td>$([ $section2_issues -eq 0 ] && echo "<span class='pass'>✓</span>" || echo "<span class='fail'>✗</span>")</td>
                    <td>$([ $section2_issues -eq 0 ] && echo "Conforme" || echo "Richiede attenzione")</td>
                </tr>
                <!-- Aggiungi altre sezioni qui -->
            </table>
        </div>
    </div>
</body>
</html>
EOF

    echo "Report HTML generato: $report_file"
}

# Genera report in formato testo
generate_text_report() {
    local report_file="apache_security_audit_$(date +%Y%m%d_%H%M%S).txt"

    {
        echo "==============================================="
        echo "       REPORT AUDIT SICUREZZA APACHE CIS       "
        echo "==============================================="
        echo
        echo "Data: $(date)"
        echo "Sistema: $(uname -a)"
        echo "Distribuzione: $DISTRO"
        echo "Versione Apache: $($APACHE_CTL -v 2>/dev/null | head -n1)"
        echo
        echo "RIEPILOGO"
        echo "----------------------------------------"
        echo "Totale controlli eseguiti: $TOTAL_CHECKS"
        echo "Controlli superati: $PASSED_CHECKS"
        echo "Controlli falliti: $FAILED_CHECKS"
        echo "Percentuale di successo: $((PASSED_CHECKS * 100 / TOTAL_CHECKS))%"
        echo
        echo "PROBLEMI RISCONTRATI"
        echo "----------------------------------------"
        echo -e "$ISSUES_FOUND"
        echo
        echo "SUGGERIMENTI PER LA CORREZIONE"
        echo "----------------------------------------"
        echo -e "$REMEDIATION_SUGGESTIONS"
        echo
        echo "==============================================="
        echo "                  FINE REPORT                  "
        echo "==============================================="
    } > "$report_file"

    echo "Report testuale generato: $report_file"
}

# Aggiungi alla fine dello script, dopo tutte le verifiche
generate_html_report
generate_text_report

echo -e "\nVerifica completata. Report generati in formato HTML e testo."
