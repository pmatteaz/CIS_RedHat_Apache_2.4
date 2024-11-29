#!/bin/bash

# Script per verificare la configurazione di sicurezza Apache secondo CIS Benchmarks
# Compatibile con Debian/Ubuntu e Red Hat/CentOS
# Richiede privilegi root per alcune verifiche

# Colori per l'output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Funzione per stampare i risultati
print_result() {
    if [ "$2" = "PASS" ]; then
        echo -e "${GREEN}[PASS]${NC} $1"
    elif [ "$2" = "FAIL" ]; then
        echo -e "${RED}[FAIL]${NC} $1"
    else
        echo -e "${YELLOW}[INFO]${NC} $1"
    fi
}

# Verifica se lo script è eseguito come root
if [ "$EUID" -ne 0 ]; then 
    echo "Per favore esegui lo script come root"
    exit 1
fi

# Determina il tipo di sistema e le path di Apache
if [ -f /etc/debian_version ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    APACHE_SERVICE="apache2"
    APACHE_USER="www-data"
    APACHE_CONFIG_FILE="$APACHE_CONFIG_DIR/apache2.conf"
    APACHE_CONTROL="apache2ctl"
elif [ -f /etc/redhat-release ]; then
    APACHE_CONFIG_DIR="/etc/httpd"
    APACHE_SERVICE="httpd"
    APACHE_USER="apache"
    APACHE_CONFIG_FILE="$APACHE_CONFIG_DIR/conf/httpd.conf"
    APACHE_CONTROL="httpd"
else
    echo "Sistema operativo non supportato"
    exit 1
fi

echo "=== Iniziando la verifica CIS Apache ==="
echo "Sistema rilevato: $(cat /etc/*release | grep "PRETTY_NAME" | cut -d= -f2- | tr -d '"')"

# 1. Verifica versione di Apache
APACHE_VERSION=$($APACHE_CONTROL -v 2>/dev/null | grep "Server version")
print_result "Versione Apache: $APACHE_VERSION" "INFO"

# 2. Verifica proprietà dei file di configurazione
check_file_permissions() {
    local file=$1
    if [ -f "$file" ]; then
        perms=$(stat -c "%a" "$file")
        owner=$(stat -c "%U" "$file")
        if [ "$perms" = "640" ] && [ "$owner" = "root" ]; then
            print_result "Permessi corretti per $file" "PASS"
        else
            print_result "Permessi non sicuri per $file ($perms, owner: $owner)" "FAIL"
        fi
    fi
}

check_file_permissions "$APACHE_CONFIG_FILE"
if [ -d "$APACHE_CONFIG_DIR/conf.d" ]; then
    check_file_permissions "$APACHE_CONFIG_DIR/conf.d/*"
fi
if [ -d "$APACHE_CONFIG_DIR/conf-available" ]; then
    check_file_permissions "$APACHE_CONFIG_DIR/conf-available/*"
fi

# 3. Verifica moduli non necessari
DANGEROUS_MODULES=("mod_info" "mod_status" "mod_userdir" "mod_proxy")
for module in "${DANGEROUS_MODULES[@]}"; do
    if $APACHE_CONTROL -M 2>/dev/null | grep -q "$module"; then
        print_result "Modulo potenzialmente pericoloso attivo: $module" "FAIL"
    else
        print_result "Modulo $module non attivo" "PASS"
    fi
done

# 4. Verifica Directory Listing
check_directory_listing() {
    if grep -r "Options.*Indexes" $APACHE_CONFIG_DIR 2>/dev/null; then
        print_result "Directory listing potrebbe essere attivo" "FAIL"
    else
        print_result "Directory listing disabilitato" "PASS"
    fi
}
check_directory_listing

# 5. Verifica Server Tokens
check_server_tokens() {
    if grep -q "^ServerTokens Prod" $APACHE_CONFIG_FILE 2>/dev/null; then
        print_result "ServerTokens configurato correttamente" "PASS"
    else
        print_result "ServerTokens potrebbe rivelare informazioni sensibili" "FAIL"
    fi
}
check_server_tokens

# 6. Verifica SSL/TLS
check_ssl_configuration() {
    local ssl_conf=""
    if [ -f "$APACHE_CONFIG_DIR/mods-enabled/ssl.conf" ]; then
        ssl_conf="$APACHE_CONFIG_DIR/mods-enabled/ssl.conf"
    elif [ -f "$APACHE_CONFIG_DIR/conf.d/ssl.conf" ]; then
        ssl_conf="$APACHE_CONFIG_DIR/conf.d/ssl.conf"
    fi

    if [ -n "$ssl_conf" ]; then
        if grep -q "SSLProtocol.*TLSv1.2" "$ssl_conf" && ! grep -q "SSLProtocol.*SSLv3" "$ssl_conf"; then
            print_result "Configurazione SSL/TLS sicura" "PASS"
        else
            print_result "Configurazione SSL/TLS potrebbe non essere ottimale" "FAIL"
        fi
    else
        print_result "Modulo SSL non trovato o non abilitato" "FAIL"
    fi
}
check_ssl_configuration

# 7. Verifica Header di Sicurezza
check_security_headers() {
    local headers=(
        "X-Frame-Options"
        "X-Content-Type-Options"
        "X-XSS-Protection"
        "Strict-Transport-Security"
    )
    
    for header in "${headers[@]}"; do
        if grep -r "$header" $APACHE_CONFIG_DIR 2>/dev/null; then
            print_result "Header di sicurezza $header configurato" "PASS"
        else
            print_result "Header di sicurezza $header non trovato" "FAIL"
        fi
    done
}
check_security_headers

# 8. Verifica file .htaccess
find_htaccess() {
    # Cerchiamo solo nelle directory web standard per evitare troppo rumore
    local web_dirs=("/var/www" "/srv/www" "/usr/local/apache2/htdocs" "/var/www/html")
    for dir in "${web_dirs[@]}"; do
        if [ -d "$dir" ]; then
            local htaccess_files=$(find "$dir" -name ".htaccess" 2>/dev/null)
            if [ -n "$htaccess_files" ]; then
                print_result "Trovati file .htaccess in $dir (verificare manualmente):" "INFO"
                echo "$htaccess_files"
            fi
        fi
    done
}
find_htaccess

# 9. Verifica CGI e script
check_cgi() {
    local cgi_dirs=("/usr/lib/cgi-bin" "/var/www/cgi-bin" "/var/www/html/cgi-bin")
    for dir in "${cgi_dirs[@]}"; do
        if [ -d "$dir" ]; then
            print_result "Directory CGI presente: $dir - verificare i permessi e il contenuto" "INFO"
            ls -la "$dir" 2>/dev/null
        fi
    done
}
check_cgi

# 10. Verifica log
check_logging() {
    local log_formats=(
        "LogFormat"
        "CustomLog"
        "ErrorLog"
    )
    
    for format in "${log_formats[@]}"; do
        if grep -q "^$format" $APACHE_CONFIG_FILE 2>/dev/null; then
            print_result "Configurazione log $format trovata" "PASS"
        else
            print_result "Configurazione log $format non trovata" "FAIL"
        fi
    done

    # Verifica permessi dei file di log
    local log_dirs=("/var/log/apache2" "/var/log/httpd")
    for dir in "${log_dirs[@]}"; do
        if [ -d "$dir" ]; then
            perms=$(stat -c "%a" "$dir")
            owner=$(stat -c "%U" "$dir")
            if [ "$perms" = "750" ] && [ "$owner" = "root" ]; then
                print_result "Permessi corretti per directory log $dir" "PASS"
            else
                print_result "Permessi non sicuri per directory log $dir ($perms, owner: $owner)" "FAIL"
            fi
        fi
    done
}
check_logging

# 11. Verifica MPM
check_mpm() {
    local mpm_module=$($APACHE_CONTROL -M 2>/dev/null | grep "mpm_" | cut -d" " -f1)
    print_result "MPM in uso: $mpm_module" "INFO"
}
check_mpm

# 12. Verifica configurazione dei timeout
check_timeouts() {
    local timeout_value=$(grep "^Timeout" $APACHE_CONFIG_FILE 2>/dev/null | awk '{print $2}')
    if [ -n "$timeout_value" ] && [ "$timeout_value" -le 300 ]; then
        print_result "Timeout configurato correttamente: $timeout_value" "PASS"
    else
        print_result "Timeout non configurato o troppo alto" "FAIL"
    fi
}
check_timeouts

echo "=== Verifica completata ==="
echo "Nota: Questo script fornisce una verifica di base. Per una validazione completa,"
echo "consultare la documentazione CIS Apache Benchmark."
