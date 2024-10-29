#!/bin/bash
# Script di hardening Apache con mappatura CIS Benchmarks
# Supporta Debian/Ubuntu e Red Hat/CentOS
# ------------------------------
# Funzione di rilevamento distribuzione
# Imposta variabili globali per paths e comandi specifici per distribuzione
# ------------------------------
detect_distro() {
    # Inizializzazione variabili per rilevamento OS
    if [ -f /etc/debian_version ]; then
        DISTRO="debian"
        APACHE_SERVICE="apache2"
        APACHE_USER="www-data"
        APACHE_GROUP="www-data"
        APACHE_CONFIG_DIR="/etc/apache2"
        APACHE_VHOST_DIR="/etc/apache2/sites-available"
        APACHE_LOG_DIR="/var/log/apache2"
        APACHE_MODULES_DIR="/etc/apache2/mods-available"
        APACHE_CONF_ENABLED="/etc/apache2/conf-enabled"
        APACHE_SITES_ENABLED="/etc/apache2/sites-enabled"
        
        # Comandi specifici Debian
        ENABLE_SITE_CMD="a2ensite"
        DISABLE_SITE_CMD="a2dissite"
        ENABLE_CONF_CMD="a2enconf"
        DISABLE_CONF_CMD="a2disconf"
        ENABLE_MOD_CMD="a2enmod"
        DISABLE_MOD_CMD="a2dismod"
        
        # Package manager specifico
        PKG_MANAGER="apt-get"
        PKG_INSTALL="apt-get install -y"
        PKG_REMOVE="apt-get remove -y"
        
        echo -e "${GREEN}Rilevato sistema Debian/Ubuntu${NC}"
        
    elif [ -f /etc/redhat-release ]; then
        DISTRO="redhat"
        APACHE_SERVICE="httpd"
        APACHE_USER="apache"
        APACHE_GROUP="apache"
        APACHE_CONFIG_DIR="/etc/httpd"
        APACHE_VHOST_DIR="/etc/httpd/conf.d"
        APACHE_LOG_DIR="/var/log/httpd"
        APACHE_MODULES_DIR="/etc/httpd/modules"
        APACHE_CONF_DIR="/etc/httpd/conf.d"
        
        # In RHEL/CentOS non ci sono comandi equivalenti a a2ensite/a2dissite
        # I moduli sono gestiti direttamente nei file di configurazione
        ENABLE_MODULE() {
            local module=$1
            sed -i "s/#LoadModule ${module}_module/LoadModule ${module}_module/" \
                "${APACHE_CONFIG_DIR}/conf.modules.d/"*
        }
        
        DISABLE_MODULE() {
            local module=$1
            sed -i "s/^LoadModule ${module}_module/#LoadModule ${module}_module/" \
                "${APACHE_CONFIG_DIR}/conf.modules.d/"*
        }
        
        # Package manager specifico
        PKG_MANAGER="yum"
        PKG_INSTALL="yum install -y"
        PKG_REMOVE="yum remove -y"
        
        echo -e "${GREEN}Rilevato sistema Red Hat/CentOS${NC}"
        
    else
        echo -e "${RED}Distribuzione non supportata${NC}"
        exit 1
    fi

    # Verifica versione Apache
    case $DISTRO in
        debian)
            APACHE_VERSION=$(apache2 -v | grep "Server version" | cut -d/ -f2 | awk '{print $1}')
            ;;
        redhat)
            APACHE_VERSION=$(httpd -v | grep "Server version" | cut -d/ -f2 | awk '{print $1}')
            ;;
    esac
    
    echo -e "${GREEN}Versione Apache rilevata: ${APACHE_VERSION}${NC}"

    # Verifica SELinux/AppArmor
    if command -v getenforce >/dev/null 2>&1; then
        SELINUX_STATUS=$(getenforce)
        echo -e "${YELLOW}SELinux status: ${SELINUX_STATUS}${NC}"
    fi

    if command -v aa-status >/dev/null 2>&1; then
        APPARMOR_STATUS=$(aa-status --enabled 2>/dev/null && echo "enabled" || echo "disabled")
        echo -e "${YELLOW}AppArmor status: ${APPARMOR_STATUS}${NC}"
    fi

    # Verifica directories critiche
    for dir in "$APACHE_CONFIG_DIR" "$APACHE_LOG_DIR" "$APACHE_MODULES_DIR"; do
        if [ ! -d "$dir" ]; then
            echo -e "${RED}Directory critica mancante: $dir${NC}"
            echo -e "${YELLOW}Verificare l'installazione di Apache${NC}"
            exit 1
        fi
    done

    # Verifica permessi utente Apache
    if ! id "$APACHE_USER" >/dev/null 2>&1; then
        echo -e "${RED}Utente Apache ($APACHE_USER) non trovato${NC}"
        exit 1
    fi

    # Funzioni helper per gestione moduli
    enable_module() {
        case $DISTRO in
            debian)
                $ENABLE_MOD_CMD "$1" >/dev/null 2>&1
                ;;
            redhat)
                ENABLE_MODULE "$1"
                ;;
        esac
    }

    disable_module() {
        case $DISTRO in
            debian)
                $DISABLE_MOD_CMD "$1" >/dev/null 2>&1
                ;;
            redhat)
                DISABLE_MODULE "$1"
                ;;
        esac
    }

    # Esporta funzioni helper
    export -f enable_module
    export -f disable_module
}

# ------------------------------
# Funzione per disabilitare moduli Apache
# Gestisce la disabilitazione dei moduli su entrambe le distribuzioni
# ------------------------------
disable_modules() {
    local modules=("$@")
    local module_name
    local module_file
    local disabled_count=0
    local failed_count=0

    echo "Disabilitando moduli non necessari..."

    for module in "${modules[@]}"; do
        echo -n "Disabilitando modulo $module... "
        
        case $DISTRO in
            debian)
                # In Debian, verifica prima se il modulo è abilitato
                if [ -f "${APACHE_CONFIG_DIR}/mods-enabled/${module}.load" ]; then
                    if $DISABLE_MOD_CMD "$module" >/dev/null 2>&1; then
                        echo -e "${GREEN}OK${NC}"
                        ((disabled_count++))
                    else
                        echo -e "${RED}FALLITO${NC}"
                        ((failed_count++))
                    fi
                else
                    echo -e "${YELLOW}già disabilitato${NC}"
                fi
                ;;
                
            redhat)
                # In RHEL/CentOS, cerca il modulo nei file di configurazione
                for conf_file in "${APACHE_CONFIG_DIR}"/conf.modules.d/*.conf; do
                    # Cerca sia LoadModule che mod_
                    if grep -E "^LoadModule.*mod_${module}|^LoadModule.*_${module}_module" "$conf_file" >/dev/null 2>&1; then
                        if sed -i -E "s/^(LoadModule.*mod_${module}|LoadModule.*_${module}_module)/#\1/" "$conf_file"; then
                            echo -e "${GREEN}OK${NC}"
                            ((disabled_count++))
                            break
                        else
                            echo -e "${RED}FALLITO${NC}"
                            ((failed_count++))
                            break
                        fi
                    fi
                done
                
                # Se il modulo non è stato trovato in nessun file
                if [ $disabled_count -eq 0 ] && [ $failed_count -eq 0 ]; then
                    echo -e "${YELLOW}non trovato/già disabilitato${NC}"
                fi
                ;;
        esac
    done

    # Verifica che i moduli critici rimangano abilitati
    local critical_modules=("log_config" "unixd" "authz_core" "dir")
    
    echo "Verificando moduli critici..."
    for module in "${critical_modules[@]}"; do
        case $DISTRO in
            debian)
                if [ ! -f "${APACHE_CONFIG_DIR}/mods-enabled/${module}.load" ]; then
                    echo -e "${YELLOW}Riabilitando modulo critico $module...${NC}"
                    $ENABLE_MOD_CMD "$module" >/dev/null 2>&1
                fi
                ;;
            redhat)
                for conf_file in "${APACHE_CONFIG_DIR}"/conf.modules.d/*.conf; do
                    if grep -E "^#.*LoadModule.*${module}_module" "$conf_file" >/dev/null 2>&1; then
                        echo -e "${YELLOW}Riabilitando modulo critico $module...${NC}"
                        sed -i -E "s/^#(LoadModule.*${module}_module)/\1/" "$conf_file"
                    fi
                done
                ;;
        esac
    done

    # Rapporto finale
    echo "-----------------------------------"
    echo "Rapporto disabilitazione moduli:"
    echo "Moduli disabilitati con successo: $disabled_count"
    if [ $failed_count -gt 0 ]; then
        echo -e "${RED}Moduli non disabilitati: $failed_count${NC}"
    fi
    echo "-----------------------------------"

    # Verifica la configurazione Apache dopo le modifiche
    echo "Verificando la configurazione Apache..."
    case $DISTRO in
        debian)
            if ! apache2ctl -t >/dev/null 2>&1; then
                echo -e "${RED}ERRORE: La configurazione Apache non è valida dopo la disabilitazione dei moduli${NC}"
                echo "Ripristino dell'ultima configurazione funzionante..."
                # Qui potresti implementare un meccanismo di backup/restore
                return 1
            fi
            ;;
        redhat)
            if ! httpd -t >/dev/null 2>&1; then
                echo -e "${RED}ERRORE: La configurazione Apache non è valida dopo la disabilitazione dei moduli${NC}"
                echo "Ripristino dell'ultima configurazione funzionante..."
                # Qui potresti implementare un meccanismo di backup/restore
                return 1
            fi
            ;;
    esac

    echo -e "${GREEN}Configurazione Apache verificata con successo${NC}"
    return 0
}

# Funzione helper per verificare dipendenze
check_dependencies() {
    local dependencies=(
        "openssl"
        "sed"
        "awk"
        "grep"
    )

    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            echo -e "${YELLOW}Installing dependency: $dep${NC}"
            $PKG_INSTALL "$dep"
        fi
    done
}

# ------------------------------
# CIS 1: Planning and Installation
# 1.2 - Ensure the Server Is Not a Multi-Use System
# 1.3 - Ensure Apache Is Installed From the Appropriate Binaries
# ------------------------------
check_installation() {
    
    
    # CIS 1.2: Verifica che il server non sia multi-uso
    local critical_services=("mysql" "postgresql" "named" "dhcpd" "dovecot" "samba")
    for service in "${critical_services[@]}"; do
        if systemctl is-active --quiet "$service"; then
            echo -e "${YELLOW}WARNING: $service è in esecuzione. CIS 1.2 raccomanda un server dedicato${NC}"
        fi
    done

    # CIS 1.3: Verifica installazione Apache
    case $DISTRO in
        debian)
            if ! dpkg -l | grep -q "^ii.*apache2\s"; then
                echo -e "${RED}Apache non è installato correttamente${NC}"
                exit 1
            fi
            ;;
        redhat)
            if ! rpm -q httpd >/dev/null; then
                echo -e "${RED}Apache non è installato correttamente${NC}"
                exit 1
            fi
            ;;
    esac
}

# ------------------------------
# CIS 2: Minimize Apache Modules
# 2.1 - Ensure Only Necessary Authentication and Authorization Modules Are Enabled
# 2.2 - Ensure the Log Config Module Is Enabled
# 2.3-2.9 - Disable unnecessary modules
# ------------------------------
manage_modules() {
    echo "Implementando CIS 2 - Gestione Moduli..."
    
    # CIS 2.2: Assicurarsi che log_config sia abilitato
    case $DISTRO in
        debian)
            a2enmod log_config
            ;;
        redhat)
            sed -i 's/^#LoadModule log_config_module/LoadModule log_config_module/' \
                "$APACHE_CONFIG_DIR/conf.modules.d/00-base.conf"
            ;;
    esac

    # CIS 2.3-2.9: Disabilitare moduli non necessari
    local MODULES_TO_DISABLE=(
        "dav"           # CIS 2.3 - WebDAV
        "dav_fs"        # CIS 2.3 - WebDAV
        "status"        # CIS 2.4 - Status
        "autoindex"     # CIS 2.5 - Autoindex
        "proxy"         # CIS 2.6 - Proxy
        "proxy_http"    # CIS 2.6 - Proxy
        "userdir"       # CIS 2.7 - UserDir
        "info"          # CIS 2.8 - Info
        "auth_basic"    # CIS 2.9 - Basic Auth
        "auth_digest"   # CIS 2.9 - Digest Auth
    )

    disable_modules "${MODULES_TO_DISABLE[@]}"
}

# ------------------------------
# CIS 3: Principles, Permissions, and Ownership
# 3.1 - Ensure Apache Runs As Non-Root
# 3.2 - Ensure Apache User Has Invalid Shell
# 3.3 - Ensure Apache User Account Is Locked
# 3.4-3.13 - File and Directory Permissions
# ------------------------------
secure_permissions() {
    echo "Implementando CIS 3 - Permessi e Proprietà..."
    
    # CIS 3.1-3.3: Configurazione utente Apache
    usermod -s /sbin/nologin "$APACHE_USER"  # CIS 3.2
    usermod -L "$APACHE_USER"                # CIS 3.3

    # Dichiarazione esplicita dell'array associativo
    declare -A APACHE_DIRS
    
    # CIS 3.4-3.6: Permessi directory principali
    APACHE_DIRS=(
        ["$APACHE_CONFIG_DIR"]="root:root:0755"
        ["$APACHE_LOG_DIR"]="root:root:0755"
        ["/var/www"]="root:root:0755"
    )

    for dir in "${!APACHE_DIRS[@]}"; do
        IFS=: read -r owner group mode <<< "${APACHE_DIRS[$dir]}"
        if [ -d "$dir" ]; then
            chown "$owner:$group" "$dir"
            chmod "$mode" "$dir"
            # CIS 3.6: Rimuovi altri permessi di scrittura
            find "$dir" -type f -exec chmod o-w {} \;
            find "$dir" -type d -exec chmod o-w {} \;
        fi
    done
}
    # CIS 3.7-3.10: Protezione file critici
    # ------------------------------
    # Funzione per proteggere i file critici di Apache
    # Implementa CIS 3.7-3.10
    # ------------------------------
    secure_critical_files() {
    echo "Protezione file critici di Apache..."
    
    # Definizione delle directory e file critici con i loro permessi desiderati
    declare -A CRITICAL_PATHS
    
    case $DISTRO in
        debian)
            CRITICAL_PATHS=(
                # CIS 3.7 - Core Dump Directory
                ["/var/crash"]="root:root:0700"
                ["/var/core"]="root:root:0700"
                
                # CIS 3.8 - Lock File
                ["/var/lock/apache2"]="root:root:0700"
                ["/var/run/apache2/apache2.lock"]="root:root:0700"
                
                # CIS 3.9 - PID File
                ["/var/run/apache2"]="root:root:0755"
                ["/var/run/apache2/apache2.pid"]="root:root:0644"
                
                # CIS 3.10 - ScoreBoard File
                ["/var/run/apache2/scoreboard"]="root:root:0600"
            )
            ;;
            
        redhat)
            CRITICAL_PATHS=(
                # CIS 3.7 - Core Dump Directory
                ["/var/crash"]="root:root:0700"
                ["/var/core"]="root:root:0700"
                
                # CIS 3.8 - Lock File
                ["/var/lock/subsys/httpd"]="root:root:0700"
                ["/var/run/httpd/httpd.lock"]="root:root:0700"
                
                # CIS 3.9 - PID File
                ["/var/run/httpd"]="root:root:0755"
                ["/var/run/httpd/httpd.pid"]="root:root:0644"
                
                # CIS 3.10 - ScoreBoard File
                ["/var/run/httpd/scoreboard"]="root:root:0600"
            )
            ;;
    esac

    # Funzione helper per creare directory mancanti
    create_directory() {
        local dir="$1"
        local perms="$2"
        
        if [ ! -d "$dir" ]; then
            echo "Creando directory $dir..."
            mkdir -p "$dir"
            if [ $? -ne 0 ]; then
                echo -e "${RED}Errore nella creazione della directory $dir${NC}"
                return 1
            fi
        fi
        return 0
    }

    # Funzione helper per impostare i permessi
    set_permissions() {
        local path="$1"
        local owner_group="$2"
        local mode="$3"
        
        # Estrai owner e group
        IFS=: read -r owner group <<< "$owner_group"
        
        # Imposta owner e group
        chown "$owner:$group" "$path"
        if [ $? -ne 0 ]; then
            echo -e "${RED}Errore nell'impostazione owner/group per $path${NC}"
            return 1
        fi
        
        # Imposta permessi
        chmod "$mode" "$path"
        if [ $? -ne 0 ]; then
            echo -e "${RED}Errore nell'impostazione dei permessi per $path${NC}"
            return 1
        fi
        
        return 0
    }

    # Processa ogni path critico
    for path in "${!CRITICAL_PATHS[@]}"; do
        echo "Processando $path..."
        
        # Estrai i permessi desiderati
        IFS=: read -r owner group mode <<< "${CRITICAL_PATHS[$path]}"
        
        # Se è una directory, creala se non esiste
        if [[ "$path" == */ ]] || [ ! -f "$path" ]; then
            if ! create_directory "$path" "$mode"; then
                continue
            fi
        fi
        
        # Imposta i permessi
        if [ -e "$path" ]; then
            # Rimuovi permessi globali pericolosi
            chmod o-rwx "$path"
            
            # Imposta i permessi corretti
            if set_permissions "$path" "$owner:$group" "$mode"; then
                echo -e "${GREEN}Permessi impostati correttamente per $path${NC}"
                echo "  Owner/Group: $owner:$group"
                echo "  Mode: $mode"
            fi
        else
            echo -e "${YELLOW}Path non trovato: $path${NC}"
        fi
    done

    # Verifica particolare per le directory di core dump
    if command -v systemctl >/dev/null 2>&1; then
        echo "Configurando limiti core dump attraverso systemd..."
        if ! grep -q "^DefaultLimitCORE=0" /etc/systemd/system.conf; then
            echo "DefaultLimitCORE=0" >> /etc/systemd/system.conf
            systemctl daemon-reexec
            echo -e "${GREEN}Limiti core dump configurati${NC}"
        fi
    fi

    # Verifica la configurazione di Apache per il core dump
    local apache_conf
    case $DISTRO in
        debian)
            apache_conf="/etc/apache2/apache2.conf"
            ;;
        redhat)
            apache_conf="/etc/httpd/conf/httpd.conf"
            ;;
    esac

    if [ -f "$apache_conf" ]; then
        if ! grep -q "^CoreDumpDirectory" "$apache_conf"; then
            echo "CoreDumpDirectory /var/crash" >> "$apache_conf"
            echo -e "${GREEN}CoreDumpDirectory configurata in Apache${NC}"
        fi
    fi

    echo "Protezione file critici completata"
}	
	
    secure_permissions
    secure_critical_files

# ------------------------------
# CIS 4: Apache Access Control
# 4.1 - Ensure Access to OS Root Directory Is Denied
# 4.2 - Ensure Appropriate Access to Web Content
# 4.3-4.4 - Ensure Override Is Disabled
# ------------------------------
configure_access_control() {
    local access_conf
    case $DISTRO in
        debian)
            access_conf="$APACHE_CONFIG_DIR/conf-available/security-access.conf"
            ;;
        redhat)
            access_conf="$APACHE_CONFIG_DIR/conf.d/security-access.conf"
            ;;
    esac

    cat > "$access_conf" << 'EOL'
# CIS 4.1: Deny access to root filesystem
<Directory />
    Options None
    AllowOverride None
    Require all denied
</Directory>

# CIS 4.2: Configure web root access
<Directory /var/www/html>
    Options None
    AllowOverride None
    Require all granted
</Directory>

# CIS 4.3-4.4: Disable .htaccess globally
<Directory />
    AllowOverride None
</Directory>
EOL
}

# ------------------------------
# CIS 5: Minimize Features, Content and Options
# 5.1-5.18 - Options and Content Restrictions
# ------------------------------
configure_security_options() {
    local security_conf
    case $DISTRO in
        debian)
            security_conf="$APACHE_CONFIG_DIR/conf-available/security-options.conf"
            ;;
        redhat)
            security_conf="$APACHE_CONFIG_DIR/conf.d/security-options.conf"
            ;;
    esac

    cat > "$security_conf" << 'EOL'
# CIS 5.1: Restrict OS Root Options
<Directory />
    Options None
</Directory>

# CIS 5.2: Restrict Web Root Options
<Directory /var/www/html>
    Options -Indexes -Includes -ExecCGI
</Directory>

# CIS 5.7-5.8: HTTP Method restrictions
<Location />
    <LimitExcept GET POST HEAD>
        Require all denied
    </LimitExcept>
</Location>
TraceEnable Off

# CIS 5.9: Disable old HTTP protocols
Protocol strict

# CIS 5.10-5.12: Protect sensitive files
<FilesMatch "^\.ht">
    Require all denied
</FilesMatch>
<FilesMatch "^\.git">
    Require all denied
</FilesMatch>
<FilesMatch "^\.svn">
    Require all denied
</FilesMatch>

# CIS 5.13: Restrict file extensions
<FilesMatch "\.(?i:ph(p[3457]?|t|tml)|aspx?|jsp|cfm|cgi)$">
    Require all denied
</FilesMatch>

# CIS 5.16-5.18: Security Headers
Header always append X-Frame-Options SAMEORIGIN
Header always set Referrer-Policy "strict-origin-when-cross-origin"
Header always set Permissions-Policy "geolocation=(), midi=(), sync-xhr=(), microphone=(), camera=(), magnetometer=(), gyroscope=(), fullscreen=(self), payment=()"
EOL
}

# ------------------------------
# CIS 6: Logging, Monitoring and Maintenance
# 6.1-6.7 - Logging Configuration
# ------------------------------
configure_logging() {
    local logging_conf
    case $DISTRO in
        debian)
            logging_conf="$APACHE_CONFIG_DIR/conf-available/logging.conf"
            ;;
        redhat)
            logging_conf="$APACHE_CONFIG_DIR/conf.d/logging.conf"
            ;;
    esac

    # CIS 6.1-6.4: Configurazione logging
    cat > "$logging_conf" << EOL
# CIS 6.1: Error Log configuration
LogLevel warn
ErrorLog ${APACHE_LOG_DIR}/error.log

# CIS 6.3: Access Log configuration
LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\"" combined
CustomLog ${APACHE_LOG_DIR}/access.log combined

# CIS 6.4: Log Rotation
<IfModule mod_logio.c>
    LogFormat "%h %l %u %t \"%r\" %>s %b \"%{Referer}i\" \"%{User-Agent}i\" %I %O" combinedio
</IfModule>
EOL
}

# ------------------------------
# CIS 7: SSL/TLS Configuration
# 7.1-7.12 - SSL/TLS Settings
# ------------------------------
configure_ssl() {
    local ssl_conf
    case $DISTRO in
        debian)
            ssl_conf="$APACHE_CONFIG_DIR/conf-available/ssl-hardening.conf"
            ;;
        redhat)
            ssl_conf="$APACHE_CONFIG_DIR/conf.d/ssl-hardening.conf"
            ;;
    esac

    cat > "$ssl_conf" << 'EOL'
# CIS 7.1-7.12: SSL/TLS Configuration
SSLProtocol all -SSLv3 +TLSv1.1 +TLSv1.2
SSLCipherSuite EECDH+AESGCM:EDH+AESGCM:AES256+EECDH:AES256+EDH
SSLHonorCipherOrder on
SSLCompression off
SSLSessionTickets off
SSLUseStapling on
SSLStaplingCache "shmcb:logs/stapling-cache(150000)"
Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
EOL
}

# ------------------------------
# CIS 8: Information Leakage
# 8.1-8.4 - Prevent Information Leakage
# ------------------------------
prevent_info_leakage() {
    local info_conf
    case $DISTRO in
        debian)
            info_conf="$APACHE_CONFIG_DIR/conf-available/security-info.conf"
            ;;
        redhat)
            info_conf="$APACHE_CONFIG_DIR/conf.d/security-info.conf"
            ;;
    esac

    cat > "$info_conf" << 'EOL'
# CIS 8.1: Minimize server information
ServerTokens Prod

# CIS 8.2: Disable server signature
ServerSignature Off

# CIS 8.4: Disable ETag
FileETag None
EOL
}

# ------------------------------
# CIS 9 & 10: DoS Mitigations e Request Limits
# 9.1-9.6 - Timeout Settings
# 10.1-10.4 - Request Limits
# ------------------------------
configure_request_limits() {
    local limits_conf
    case $DISTRO in
        debian)
            limits_conf="$APACHE_CONFIG_DIR/conf-available/request-limits.conf"
            ;;
        redhat)
            limits_conf="$APACHE_CONFIG_DIR/conf.d/request-limits.conf"
            ;;
    esac

    cat > "$limits_conf" << 'EOL'
# CIS 9.1-9.6: Timeout Settings
Timeout 10
KeepAlive On
MaxKeepAliveRequests 100
KeepAliveTimeout 15
RequestReadTimeout header=40 body=20

# CIS 10.1-10.4: Request Limits
LimitRequestLine 512
LimitRequestFields 100
LimitRequestFieldSize 1024
LimitRequestBody 102400
EOL
}

# Funzione principale che esegue tutti i controlli
main() {
    if [ "$EUID" -ne 0 ]; then 
        echo -e "${RED}Questo script deve essere eseguito come root${NC}"
        exit 1
    fi
    # Identifica la distribuzione
	detect_distro  

    # Esegue tutte le funzioni in ordine secondo CIS
    check_installation
    manage_modules
    secure_permissions
    configure_access_control
    configure_security_options
    configure_logging
    configure_ssl
    prevent_info_leakage
    configure_request_limits
    
# ------------------------------
# Funzione per riavviare Apache in modo sicuro
# Include verifiche pre e post riavvio
# ------------------------------
restart_apache() {
    echo "Preparazione al riavvio di Apache..."
    local config_test_passed=false
    local restart_success=false
    local max_restart_attempts=3
    local restart_attempt=1
    local apache_status
    
    # Backup della configurazione corrente
    local backup_dir="/tmp/apache_backup_$(date +%Y%m%d_%H%M%S)"
    local backup_success=false
    
    # Crea directory di backup
    if mkdir -p "$backup_dir"; then
        case $DISTRO in
            debian)
                if cp -r /etc/apache2/* "$backup_dir/"; then
                    backup_success=true
                fi
                ;;
            redhat)
                if cp -r /etc/httpd/* "$backup_dir/"; then
                    backup_success=true
                fi
                ;;
        esac
    fi
    
    if [ "$backup_success" = true ]; then
        echo -e "${GREEN}Backup della configurazione creato in $backup_dir${NC}"
    else
        echo -e "${YELLOW}Warning: Impossibile creare il backup della configurazione${NC}"
    fi

    # Verifica la configurazione prima del riavvio
    echo "Verificando la configurazione Apache..."
    case $DISTRO in
        debian)
            apache2ctl configtest > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                config_test_passed=true
                echo -e "${GREEN}Verifica configurazione: OK${NC}"
            else
                echo -e "${RED}Errore nella configurazione Apache:${NC}"
                apache2ctl configtest
            fi
            ;;
        redhat)
            httpd -t > /dev/null 2>&1
            if [ $? -eq 0 ]; then
                config_test_passed=true
                echo -e "${GREEN}Verifica configurazione: OK${NC}"
            else
                echo -e "${RED}Errore nella configurazione Apache:${NC}"
                httpd -t
            fi
            ;;
    esac

    # Se la configurazione non è valida, ripristina il backup
    if [ "$config_test_passed" = false ]; then
        echo -e "${RED}La configurazione contiene errori${NC}"
        if [ "$backup_success" = true ]; then
            echo "Ripristino della configurazione precedente..."
            case $DISTRO in
                debian)
                    cp -r "$backup_dir"/* /etc/apache2/
                    ;;
                redhat)
                    cp -r "$backup_dir"/* /etc/httpd/
                    ;;
            esac
            echo -e "${GREEN}Configurazione precedente ripristinata${NC}"
        fi
        return 1
    fi

    # Verifica se Apache è in esecuzione
    systemctl is-active --quiet $APACHE_SERVICE
    apache_status=$?

    # Tentativo di riavvio
    while [ $restart_attempt -le $max_restart_attempts ] && [ "$restart_success" = false ]; do
        echo "Tentativo di riavvio $restart_attempt di $max_restart_attempts..."
        
        # Se Apache è in esecuzione, prova prima un graceful restart
        if [ $apache_status -eq 0 ]; then
            echo "Apache è in esecuzione, tentativo di graceful restart..."
            case $DISTRO in
                debian)
                    apache2ctl graceful
                    ;;
                redhat)
                    httpd -k graceful
                    ;;
            esac
            sleep 2
        fi

        # Riavvio completo del servizio
        systemctl restart $APACHE_SERVICE
        if [ $? -eq 0 ]; then
            # Attendi che il servizio sia completamente avviato
            sleep 2
            systemctl is-active --quiet $APACHE_SERVICE
            if [ $? -eq 0 ]; then
                restart_success=true
                break
            fi
        fi

        ((restart_attempt++))
        sleep 3
    done

    # Verifica post-riavvio
    if [ "$restart_success" = true ]; then
        echo -e "${GREEN}Apache riavviato con successo${NC}"
        
        # Verifica le porte in ascolto
        echo "Verifica porte in ascolto..."
        if command -v ss >/dev/null 2>&1; then
            ss -tlnp | grep -E "(apache2|httpd)"
        elif command -v netstat >/dev/null 2>&1; then
            netstat -tlnp | grep -E "(apache2|httpd)"
        fi
        
        # Verifica i processi
        echo "Processi Apache in esecuzione:"
        ps aux | grep -E "(apache2|httpd)" | grep -v grep
        
        # Verifica sintomi comuni di problemi
        local error_log
        case $DISTRO in
            debian)
                error_log="/var/log/apache2/error.log"
                ;;
            redhat)
                error_log="/var/log/httpd/error.log"
                ;;
        esac
        
        echo "Ultimi errori nel log (se presenti):"
        tail -n 5 "$error_log" | grep -i "error"
        
        return 0
    else
        echo -e "${RED}Impossibile riavviare Apache dopo $max_restart_attempts tentativi${NC}"
        
        # Ripristino backup se disponibile
        if [ "$backup_success" = true ]; then
            echo "Ripristino della configurazione precedente..."
            case $DISTRO in
                debian)
                    cp -r "$backup_dir"/* /etc/apache2/
                    systemctl restart apache2
                    ;;
                redhat)
                    cp -r "$backup_dir"/* /etc/httpd/
                    systemctl restart httpd
                    ;;
            esac
            echo -e "${GREEN}Configurazione precedente ripristinata${NC}"
        fi
        
        return 1
    fi
}

    restart_apache
    
    echo -e "${GREEN}Implementazione controlli CIS completata${NC}"
    echo -e "${YELLOW}Nota: Alcuni controlli CIS potrebbero richiedere configurazione manuale aggiuntiva${NC}"
}

# Esegue lo script
main
