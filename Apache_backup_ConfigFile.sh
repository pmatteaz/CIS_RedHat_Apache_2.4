#!/bin/bash

# Imposta la directory di backup
BACKUP_DIR="/root/backups"
DATE=$(date +%Y%m%d_%H%M%S)
BACKUP_PATH="${BACKUP_DIR}/apache_backup_${DATE}"

# Funzione per trovare il file di configurazione principale
find_apache_conf() {
    if [ -f /etc/httpd/conf/httpd.conf ]; then
        echo "/etc/httpd/conf/httpd.conf"  # RedHat/CentOS
    elif [ -f /etc/apache2/apache2.conf ]; then
        echo "/etc/apache2/apache2.conf"   # Debian/Ubuntu
    else
        echo ""
    fi
}

# Funzione per estrarre i percorsi Include dal file di configurazione
get_include_paths() {
    local conf_file=$1
    grep -i "^[[:space:]]*Include" "$conf_file" | awk '{print $2}' | sed 's/"//g'
}

# Crea la directory di backup
mkdir -p "${BACKUP_PATH}"

# Trova il file di configurazione principale
APACHE_CONF=$(find_apache_conf)
if [ -z "$APACHE_CONF" ]; then
    echo "Errore: Impossibile trovare il file di configurazione di Apache"
    exit 1
fi

# Backup della directory principale di Apache
if [ -d "/etc/httpd" ]; then
    # Crea la directory di backup
    BACKUP_PATH=${BACKUP_PATH}/httpd
    mkdir -p "${BACKUP_PATH}"
    cp -r /etc/httpd/conf* "${BACKUP_PATH}"  # RedHat/CentOS
elif [ -d "/etc/apache2" ]; then
    # Crea la directory di backup
    BACKUP_PATH=${BACKUP_PATH}/apache2
    mkdir -p "${BACKUP_PATH}"
    cp -r /etc/apache2/* "${BACKUP_PATH}"  # Debian/Ubuntu
fi

# Backup delle directory degli include specificate in httpd.conf
while IFS= read -r include_path; do
    # Gestisce percorsi con wildcard
    if [[ $include_path == *"*"* ]]; then
        dir_path=$(dirname "$include_path")
        if [ -d "$dir_path" ]; then
            mkdir -p "${BACKUP_PATH}/includes$(dirname $include_path)"
            cp -r "$dir_path"/* "${BACKUP_PATH}/includes$dir_path/"
        fi
    else
        if [ -f "$include_path" ]; then
            mkdir -p "${BACKUP_PATH}/includes$(dirname $include_path)"
            cp "$include_path" "${BACKUP_PATH}/includes$include_path"
        elif [ -d "$include_path" ]; then
            mkdir -p "${BACKUP_PATH}/includes$include_path"
            cp -r "$include_path"/* "${BACKUP_PATH}/includes$include_path/"
        fi
    fi
done < <(get_include_paths "$APACHE_CONF")

# Comprimi il backup
cd "${BACKUP_DIR}"
tar -czf "apache_backup_${DATE}.tar.gz" "apache_backup_${DATE}"
BACKUP_PATH=$(dirname BACKUP_PATH)
rm -rf "${BACKUP_PATH}"

echo "Backup completato in: ${BACKUP_DIR}/apache_backup_${DATE}.tar.gz"
