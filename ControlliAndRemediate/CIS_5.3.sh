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

print_section "Verifica CIS 5.3: Options per Tutte le Directory"

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

# Array per memorizzare le directory con Options non sicure
declare -a insecure_directories=()

print_section "Ricerca File di Configurazione"

# Trova tutti i file di configurazione Apache
while IFS= read -r -d '' file; do
    if file "$file" | grep -q "text"; then
        CONFIG_FILES+=("$file")
        echo "Trovato file di configurazione: $file"
    fi
done < <(find "$APACHE_CONFIG_DIR" -type f -name "*.conf" -print0)

print_section "Verifica Configurazione Options"

# Lista delle options pericolose da controllare
declare -a DANGEROUS_OPTIONS=(
    "All"
    "ExecCGI"
    "FollowSymLinks"
    "Includes"
    "MultiViews"
    "Indexes"
    "SymLinksIfOwnerMatch"
)

# Funzione per verificare le Options in una sezione Directory
check_directory_options() {
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
            current_directory=$(echo "$line" | sed -n 's/.*<Directory[[:space:]]*\([^>]*\).*/\1/p')
            continue
        fi
        
        # Cerca fine sezione Directory
        if [[ "$line" == "</Directory>" ]]; then
            in_directory=false
            continue
        fi
        
        # Se siamo in una sezione Directory, cerca Options
        if $in_directory; then
            if [[ "$line" =~ ^"Options"[[:space:]] ]]; then
                if ! [[ "$line" =~ ^"Options None"$ ]]; then
                    # Verifica se ci sono options pericolose
                    for option in "${DANGEROUS_OPTIONS[@]}"; do
                        if echo "$line" | grep -q "$option"; then
                            insecure_directories+=("$file:$line_number:$current_directory:$line")
                            echo -e "${RED}✗ Directory $current_directory ha Options non sicure: $line${NC}"
                            break
                        fi
                    done
                fi
            fi
        fi
    done < "$file"
}

# Controlla tutti i file di configurazione
for config_file in "${CONFIG_FILES[@]}"; do
    check_directory_options "$config_file"
done

# Se ci sono problemi, offri remediation
if [ ${#insecure_directories[@]} -gt 0 ]; then
    echo -e "\n${YELLOW}Sono state trovate ${#insecure_directories[@]} directory con Options non sicure.${NC}"
    echo -e "${YELLOW}Vuoi procedere con la remediation? (s/n)${NC}"
    read -r risposta
    
    if [[ "$risposta" =~ ^[Ss]$ ]]; then
        print_section "Esecuzione Remediation"
        
        # Backup dei file di configurazione
        timestamp=$(date +%Y%m%d_%H%M%S)
        backup_dir="/root/apache_directory_options_backup_$timestamp"
        mkdir -p "$backup_dir"
        
        echo "Creazione backup in $backup_dir..."
        for config_file in "${CONFIG_FILES[@]}"; do
            rel_path=${config_file#$APACHE_CONFIG_DIR}
            backup_path="$backup_dir$(dirname "$rel_path")"
            mkdir -p "$backup_path"
            cp -p "$config_file" "$backup_path/"
        done
        
        # Correggi le configurazioni
        echo -e "\n${YELLOW}Correzione configurazioni Options...${NC}"
        
        for entry in "${insecure_directories[@]}"; do
            # Estrai informazioni dall'entry
            file=$(echo "$entry" | cut -d: -f1)
            line_num=$(echo "$entry" | cut -d: -f2)
            directory=$(echo "$entry" | cut -d: -f3)
            
            echo "Correzione in $file per directory $directory"
            
            # Sostituisci la riga con "Options None"
            sed -i "${line_num}s/Options.*/Options None/" "$file"
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
                declare -a new_insecure_dirs=()
                
                # Ricontrolla tutti i file
                for config_file in "${CONFIG_FILES[@]}"; do
                    while IFS= read -r line; do
                        if [[ "$line" =~ "Options" ]] && ! [[ "$line" =~ "Options None" ]]; then
                            for option in "${DANGEROUS_OPTIONS[@]}"; do
                                if echo "$line" | grep -q "$option"; then
                                    new_insecure_dirs+=("$config_file:$line")
                                    break
                                fi
                            done
                        fi
                    done < <(grep -n "Options" "$config_file")
                done
                
                if [ ${#new_insecure_dirs[@]} -eq 0 ]; then
                    echo -e "${GREEN}✓ Tutte le directory sono state configurate correttamente${NC}"
                    
                    # Test pratici
                    echo -e "\n${YELLOW}Esecuzione test di configurazione...${NC}"
                    
                    # Crea directory di test
                    test_dir="/var/www/html/test_options"
                    mkdir -p "$test_dir"
                    
                    # Test vari
                    echo "Test content" > "$test_dir/test.html"
                    ln -s /etc/passwd "$test_dir/test_symlink" 2>/dev/null
                    echo "<!--#exec cmd=\"ls\" -->" > "$test_dir/test.shtml"
                    
                    # Test directory listing
                    if curl -s "http://localhost/test_options/" | grep -qi "Index of"; then
                        echo -e "${RED}✗ Directory listing ancora attivo${NC}"
                    else
                        echo -e "${GREEN}✓ Directory listing disabilitato${NC}"
                    fi
                    
                    # Test symlinks
                    if curl -s "http://localhost/test_options/test_symlink" | grep -q "root:"; then
                        echo -e "${RED}✗ FollowSymLinks ancora attivo${NC}"
                    else
                        echo -e "${GREEN}✓ FollowSymLinks disabilitato${NC}"
                    fi
                    
                    # Test SSI
                    if curl -s "http://localhost/test_options/test.shtml" | grep -q "bin"; then
                        echo -e "${RED}✗ Server Side Includes ancora attivi${NC}"
                    else
                        echo -e "${GREEN}✓ Server Side Includes disabilitati${NC}"
                    fi
                    
                    # Pulizia
                    rm -rf "$test_dir"
                    
                else
                    echo -e "${RED}✗ Alcune directory presentano ancora problemi${NC}"
                    printf '%s\n' "${new_insecure_dirs[@]}"
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
    echo -e "\n${GREEN}✓ Tutte le directory hanno Options configurate correttamente${NC}"
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

echo -e "\n${BLUE}Nota: La corretta configurazione delle Options per tutte le directory garantisce che:${NC}"
echo -e "${BLUE}- Ogni directory abbia solo le options strettamente necessarie${NC}"
echo -e "${BLUE}- Non siano abilitate funzionalità potenzialmente pericolose${NC}"
echo -e "${BLUE}- La sicurezza sia massimizzata per ogni percorso${NC}"
echo -e "${BLUE}- L'accesso alle risorse sia controllato in modo appropriato${NC}"
