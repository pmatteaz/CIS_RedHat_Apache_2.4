#!/bin/bash
## Manuale da mettere apposto.

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

print_section "Verifica CIS 4.4: AllowOverride Disabilitato per Tutte le Directory"

# Verifica se Apache è installato
if ! command_exists httpd && ! command_exists apache2; then
    echo -e "${RED}Apache non sembra essere installato sul sistema${NC}"
    exit 1
fi

# Determina il tipo di sistema e i percorsi
if [ -f /etc/redhat-release ]; then
    APACHE_CONFIG_DIR="/etc/httpd"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/conf/httpd.conf"
elif [ -f /etc/debian_version ]; then
    APACHE_CONFIG_DIR="/etc/apache2"
    MAIN_CONFIG="$APACHE_CONFIG_DIR/apache2.conf"
else
    echo -e "${RED}Sistema operativo non supportato${NC}"
    exit 1
fi

# Array per memorizzare i file di configurazione da controllare
declare -a CONFIG_FILES=()

# Array per memorizzare le directory con AllowOverride non corretto
declare -a wrong_override=()

print_section "Ricerca File di Configurazione"

# Trova tutti i file di configurazione Apache
while IFS= read -r -d '' file; do
    if file "$file" | grep -q "text"; then
        CONFIG_FILES+=("$file")
        echo "Trovato file di configurazione: $file"
    fi
done < <(find "$APACHE_CONFIG_DIR" -type f -name "*.conf" -print0)

print_section "Verifica Configurazione AllowOverride"

# Funzione per verificare AllowOverride in un file
check_override_settings() {
    local file="$1"
    local in_directory=false
    local current_directory=""
    local line_number=0
    
    echo -e "\nAnalisi file: $file"
    
    while IFS= read -r line; do
        ((line_number++))
        # Rimuovi spazi iniziali e finali
        line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        # Cerca inizio sezione Directory
        if [[ "$line" =~ ^"<Directory"[[:space:]] ]]; then
            in_directory=true
            current_directory=$line
            current_start=$line_number
            continue
        fi
        
        # Cerca fine sezione Directory
        if [[ "$line" == "</Directory>" ]]; then
            in_directory=false
            continue
        fi
        
        # Se siamo in una sezione Directory, cerca AllowOverride
        if $in_directory; then
            if [[ "$line" =~ ^"AllowOverride"[[:space:]] ]]; then
                if ! [[ "$line" =~ ^"AllowOverride None"$ ]]; then
                    wrong_override+=("$file:$line_number:$current_directory:$line")
                    echo -e "${RED}✗ AllowOverride non corretto trovato in $file alla riga $line_number${NC}"
                    echo "  Directory: $current_directory"
                    echo "  Configurazione: $line"
                fi
            fi
        fi
    done < "$file"
}

# Controlla tutti i file di configurazione
for config_file in "${CONFIG_FILES[@]}"; do
    check_override_settings "$config_file"
done

# Se ci sono problemi, offri remediation
if [ ${#wrong_override[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono stati trovati ${#wrong_override[@]} casi di AllowOverride non correttamente configurati.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup dei file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_allowoverride_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        for config_file in "${CONFIG_FILES[@]}"; do
            rel_path=${config_file#$APACHE_CONFIG_DIR}
            backup_path="$backup_dir$(dirname "$rel_path")"
            mkdir -p "$backup_path"
            cp -p "$config_file" "$backup_path/"
        done
        
        # Correggi le configurazioni
        echo -e "\n${YELLOW}Correzione configurazioni AllowOverride...${NC}"
        
        for entry in "${wrong_override[@]}"; do
            # Estrai informazioni dall'entry
            file=$(echo "$entry" | cut -d: -f1)
            line_num=$(echo "$entry" | cut -d: -f2)
            
            echo "Correzione in $file riga $line_num"
            
            # Sostituisci la riga con "AllowOverride None"
            sed -i "${line_num}s/AllowOverride.*/AllowOverride None/" "$file"
        done
        
        # Verifica la configurazione di Apache
        echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
        if httpd -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
            echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"
            
            # Riavvio di Apache
            echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
            if systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null; then
                echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
                
                # Verifica finale
                print_section "Verifica Finale"
                
                # Array per memorizzare nuovi problemi trovati
                declare -a new_wrong_override=()
                
                # Ricontrolla tutti i file
                for config_file in "${CONFIG_FILES[@]}"; do
                    while IFS= read -r line; do
                        if [[ "$line" =~ "AllowOverride" ]] && ! [[ "$line" =~ "AllowOverride None" ]]; then
                            new_wrong_override+=("$config_file:$line")
                        fi
                    done < <(grep -n "AllowOverride" "$config_file")
                done
                
                if [ ${#new_wrong_override[@]} -eq 0 ]; then
                    echo -e "${GREEN}✓ Tutte le direttive AllowOverride sono state corrette${NC}"
                    
                    # Test pratico
                    echo -e "\n${YELLOW}Esecuzione test di configurazione...${NC}"
                    
                    # Test con .htaccess in varie directory
                    for dir in "/var/www/html" "/var/www"; do
                        if [ -d "$dir" ]; then
                            test_htaccess="$dir/.htaccess"
                            echo "Options +Indexes" > "$test_htaccess"
                            if curl -s "http://localhost${dir#/var/www/html}" | grep -q "403"; then
                                echo -e "${GREEN}✓ Override correttamente disabilitato in $dir${NC}"
                            else
                                echo -e "${RED}✗ Override potrebbe essere ancora attivo in $dir${NC}"
                            fi
                            rm -f "$test_htaccess"
                        fi
                    done
                else
                    echo -e "${RED}✗ Alcune direttive AllowOverride non sono state corrette correttamente${NC}"
                    echo "Problemi rimanenti:"
                    printf '%s\n' "${new_wrong_override[@]}"
                fi
                
            else
                echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
            fi
        else
            echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
            echo -e "${YELLOW}Ripristino del backup...${NC}"
            
            # Ripristina tutti i file dal backup
            for config_file in "${CONFIG_FILES[@]}"; do
                rel_path=${config_file#$APACHE_CONFIG_DIR}
                cp "$backup_dir$rel_path" "$config_file"
            done
            
            systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
            echo -e "${GREEN}Backup ripristinato${NC}"
        fi
        
    else
        echo -e "${YELLOW}Remediation annullata dall'utente${NC}"
    fi
else
    echo -e "\n${GREEN}✓ Tutte le direttive AllowOverride sono configurate correttamente${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione controllati:"
for config_file in "${CONFIG_FILES[@]}"; do
    echo "   - $config_file"
done
if [ -d "$backup_dir" ]; then
    echo "2. Backup salvato in: $backup_dir"
fi
