#!/bin/bash

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Funzione per stampare intestazioni delle sezioni
print_section() {
    echo -e "\n${BLUE}=== $1 ===${NC}"
}

# Funzione per verificare se un comando esiste
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

print_section "CIS Control 3.12 - Verifica Permessi DocumentRoot"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    SYSTEM_TYPE="redhat"
    APACHE_CMD="httpd"
    APACHE_CONF="/etc/httpd/conf/httpd.conf"
    APACHE_USER="apache"
    APACHE_GROUP="apache"
else
    SYSTEM_TYPE="debian"
    APACHE_CMD="apache2"
    APACHE_CONF="/etc/apache2/apache2.conf"
    APACHE_USER="www-data"
    APACHE_GROUP="www-data"
fi

# Array per memorizzare i problemi trovati
declare -a issues_found=()

# Funzione per ottenere il DocumentRoot
get_document_root() {
    local docroot=$(grep "^DocumentRoot" "$APACHE_CONF" | awk '{print $2}' | tr -d '"')
    if [ -z "$docroot" ]; then
        if [ "$SYSTEM_TYPE" = "redhat" ]; then
            echo "/var/www/html"
        else
            echo "/var/www/html"
        fi
    else
        echo "$docroot"
    fi
}

print_section "Verifica Configurazione DocumentRoot"

# Funzione per verificare permessi di un singolo file/directory
check_permissions() {
    local path="$1"
    local is_dir="$2"
    local problems=0

    # Ottieni proprietario e permessi
    local perms=$(stat -c "%a" "$path")
    local owner=$(stat -c "%U" "$path")
    local group=$(stat -c "%G" "$path")

    # Verifica permessi
    if [ "$is_dir" = "true" ]; then
        if [ "$perms" -gt "755" ]; then
            echo -e "${RED}✗ Directory $path ha permessi troppo permissivi ($perms)${NC}"
            problems=1
        fi
    else
        if [ "$perms" -gt "644" ]; then
            echo -e "${RED}✗ File $path ha permessi troppo permissivi ($perms)${NC}"
            problems=1
        fi
    fi

#    # Verifica proprietario
#    if [ "$owner" != "$APACHE_USER" ] || [ "$group" != "$APACHE_GROUP" ]; then
#        echo -e "${RED}✗ $path non appartiene a $APACHE_USER:$APACHE_GROUP (attuale: $owner:$group)${NC}"
#        problems=1
#    fi
#
    if [ $problems -eq 1 ]; then
        issues_found+=("wrong_perms_$path")
        return 1
    fi
    return 0
}

# Funzione per verificare ricorsivamente directory e file
check_directory_recursive() {
    local dir="$1"
    local total_items=0
    local checked_items=0

    # Conta il numero totale di elementi
    total_items=$(find "$dir" -type f -o -type d | wc -l)

    echo -e "\n${BLUE}Verifica ricorsiva di $dir (totale elementi: $total_items)${NC}"

    # Verifica la directory principale
    echo -e "\n${YELLOW}Controllo directory principale $dir${NC}"
    check_permissions "$dir" true

    # Verifica tutte le sottodirectory
    while IFS= read -r -d '' subdir; do
        echo -e "\n${YELLOW}Controllo directory $subdir${NC}"
        check_permissions "$subdir" true
        ((checked_items++))
        echo -e "${BLUE}Progresso: $checked_items/$total_items${NC}"
    done < <(find "$dir" -mindepth 1 -type d -print0)

    # Verifica tutti i file
    while IFS= read -r -d '' file; do
        echo -e "\n${YELLOW}Controllo file $file${NC}"
        check_permissions "$file" false
        ((checked_items++))
        echo -e "${BLUE}Progresso: $checked_items/$total_items${NC}"
    done < <(find "$dir" -type f -print0)
}

# Funzione principale di verifica
check_docroot_permissions() {
    local docroot=$(get_document_root)
    echo "Controllo DocumentRoot: $docroot"

    if [ ! -d "$docroot" ]; then
        echo -e "${RED}✗ DocumentRoot non esiste${NC}"
        issues_found+=("no_docroot")
        return 1
    fi

    # Verifica ricorsiva della DocumentRoot
    check_directory_recursive "$docroot"

    if [ ${#issues_found[@]} -eq 0 ]; then
        return 0
    else
        return 1
    fi
}

# Esegui la verifica
check_docroot_permissions

# Funzioni per il backup
do_backup() {
    local dir="$1"
    local backup_file="$2"
    local total_items=0
    local processed_items=0

    # Conta il numero totale di elementi
    echo -e "${BLUE}Conteggio elementi...${NC}"
    total_items=$(find "$dir" -print | wc -l)

    echo -e "${GREEN}Inizio backup permessi per $dir${NC}"
    echo -e "${BLUE}Totale elementi da processare: $total_items${NC}"

    # Intestazione file di backup
    echo "# Backup permessi generato il $(date)" > "$backup_file"
    echo "# Directory base: $dir" >> "$backup_file"
    echo "# Formato: PATH PERMS OWNER:GROUP" >> "$backup_file"

    # Salva i permessi di ogni file e directory
    find "$dir" -print0 | while IFS= read -r -d $'\0' item; do
        # Ottieni permessi e proprietario in formato leggibile
        perms=$(stat -c '%a' "$item")
        owner=$(stat -c '%U:%G' "$item")

        # Salva il percorso relativo
        rel_path="${item#$dir}"
        if [ -z "$rel_path" ]; then
            rel_path="/"
        fi

        # Scrivi nel file di backup
        echo "$rel_path $perms $owner" >> "$backup_file"

        # Aggiorna contatore e mostra progresso
        ((processed_items++))
        printf "\r${BLUE}Progresso: ${processed_items}/${total_items} elementi processati${NC}"
    done

    echo -e "\n${GREEN}Backup completato! File salvato in: $backup_file${NC}"
    echo -e "${BLUE}Statistiche backup:${NC}"
    echo "- Totale elementi processati: $processed_items"
    echo "- File di backup: $backup_file"
    echo "- Dimensione backup: $(du -h "$backup_file" | cut -f1)"
}

# Funzione per il ripristino dei permessi
do_restore() {
    local dir="$1"
    local backup_file="$2"
    local total_items=0
    local processed_items=0
    local errors=0

    if [ ! -f "$backup_file" ]; then
        echo -e "${RED}Errore: File di backup $backup_file non trovato${NC}"
        exit 1
    fi

    # Verifica che il backup sia per la directory corretta
    base_dir=$(grep "^# Directory base:" "$backup_file" | cut -d: -f2- | tr -d ' ')
    if [ "$dir" != "$base_dir" ]; then
        echo -e "${YELLOW}Attenzione: La directory di backup ($base_dir) non corrisponde alla directory target ($dir)${NC}"
        read -p "Vuoi continuare comunque? (s/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Ss]$ ]]; then
            exit 1
        fi
    fi

    # Conta il numero totale di elementi
    total_items=$(grep -v '^#' "$backup_file" | wc -l)
    echo -e "${GREEN}Inizio ripristino permessi da $backup_file${NC}"
    echo -e "${BLUE}Totale elementi da processare: $total_items${NC}"

    # Leggi il file di backup ed elabora ogni riga
    while IFS=' ' read -r path perms owner || [ -n "$path" ]; do
        # Salta le righe di commento
        [[ "$path" =~ ^#.*$ ]] && continue

        # Costruisci il percorso completo
        full_path="$dir$path"

        # Se il percorso è solo "/" usa la directory base
        if [ "$path" = "/" ]; then
            full_path="$dir"
        fi

        if [ -e "$full_path" ]; then
            # Ripristina proprietario e gruppo
            if ! chown "$owner" "$full_path" 2>/dev/null; then
                echo -e "\n${RED}Errore nel ripristino del proprietario per: $full_path${NC}"
                ((errors++))
            fi

            # Ripristina permessi
            if ! chmod "$perms" "$full_path" 2>/dev/null; then
                echo -e "\n${RED}Errore nel ripristino dei permessi per: $full_path${NC}"
                ((errors++))
            fi
        else
            echo -e "\n${YELLOW}Attenzione: $full_path non esiste${NC}"
            ((errors++))
        fi

        # Aggiorna contatore e mostra progresso
        ((processed_items++))
        printf "\r${BLUE}Progresso: ${processed_items}/${total_items} elementi processati${NC}"
    done < "$backup_file"

    echo -e "\n${GREEN}Ripristino completato!${NC}"
    echo -e "${BLUE}Statistiche ripristino:${NC}"
    echo "- Totale elementi processati: $processed_items"
    echo "- Errori riscontrati: $errors"

    if [ $errors -gt 0 ]; then
        echo -e "${YELLOW}Ci sono stati alcuni errori durante il ripristino${NC}"
    fi
}

# Funzione per correggere permessi ricorsivamente
fix_permissions_recursive() {
    local dir="$1"
    local total_items=0
    local fixed_items=0

    # Conta il numero totale di elementi
    total_items=$(find "$dir" -type f -o -type d | wc -l)

    echo -e "\n${BLUE}Correzione permessi in $dir (totale elementi: $total_items)${NC}"

    # Correggi la directory principale
    echo -e "\n${YELLOW}Correzione directory principale $dir${NC}"
    #chown "$APACHE_USER:$APACHE_GROUP" "$dir"
    chmod 755 "$dir"

    # Correggi tutte le sottodirectory
    while IFS= read -r -d '' subdir; do
        echo -e "\n${YELLOW}Correzione directory $subdir${NC}"
    #    chown "$APACHE_USER:$APACHE_GROUP" "$subdir"
        chmod 755 "$subdir"
        ((fixed_items++))
        echo -e "${BLUE}Progresso: $fixed_items/$total_items${NC}"
    done < <(find "$dir" -mindepth 1 -type d -print0)

    # Correggi tutti i file
    while IFS= read -r -d '' file; do
        echo -e "\n${YELLOW}Correzione file $file${NC}"
    #    chown "$APACHE_USER:$APACHE_GROUP" "$file"
        chmod 644 "$file"
        ((fixed_items++))
        echo -e "${BLUE}Progresso: $fixed_items/$total_items${NC}"
    done < <(find "$dir" -type f -print0)
}

# Se ci sono problemi, offri remediation
if [ ${#issues_found[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Problemi rilevati nei permessi della DocumentRoot.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta

    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"

        # Backup delle configurazioni e contenuti
        timestamp=$(date +%Y%m%d_%H%M%S)_CIS_3.12
        backup_dir="/root/docroot_backup_$timestamp"
        mkdir -p "$backup_dir"

        docroot=$(get_document_root)
        echo "Creazione backup in $backup_dir..."
        # fai backup permessi
        do_backup "$docroot" "$backup_dir/permessi.txt"

        # Applica le correzioni
        echo -e "\n${YELLOW}Correzione permessi DocumentRoot...${NC}"
        fix_permissions_recursive "$docroot"

        # Verifica la configurazione di Apache
        echo -e "\n${YELLOW}Verifica configurazione Apache...${NC}"
        if $APACHE_CMD -t; then
            echo -e "${GREEN}✓ Configurazione Apache valida${NC}"

            # Riavvia Apache
            echo -e "\n${YELLOW}Riavvio Apache...${NC}"
            systemctl restart $APACHE_CMD

            if [ $? -eq 0 ]; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"

                # Verifica finale
                print_section "Verifica Finale"
                issues_found=()
                if check_docroot_permissions; then
                    echo -e "\n${GREEN}✓ Permessi DocumentRoot corretti${NC}"
                else
                    echo -e "\n${RED}✗ Problemi nei permessi persistono${NC}"
                fi
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            do_restore "$docroot" "$backup_dir/permessi.txt"
            systemctl restart $APACHE_CMD
        fi
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ I permessi della DocumentRoot sono corretti${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. DocumentRoot: $(get_document_root)"
if [ -d "$backup_dir" ]; then
    echo "4. Backup salvato in: $backup_dir"
fi

# Statistiche finali
if [ -d "$(get_document_root)" ]; then
    print_section "Statistiche DocumentRoot"
    echo "Totale directories: $(find "$(get_document_root)" -type d | wc -l)"
    echo "Totale files: $(find "$(get_document_root)" -type f | wc -l)"
    echo "Spazio occupato: $(du -sh "$(get_document_root)" | cut -f1)"
fi
