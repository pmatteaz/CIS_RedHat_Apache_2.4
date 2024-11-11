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

# Funzione per modificare o inserire la configurazione LimitExcept in una sezione Directory
modify_directory_section() {
    local file="$1"
    local temp_file=$(mktemp)
    local in_directory=false
    local changes_made=false
    local current_directory=""
    local line_buffer=""

    while IFS= read -r line || [ -n "$line" ]; do
        # Identifica l'inizio di una sezione Directory
        if [[ $line =~ ^[[:space:]]*\<Directory[[:space:]]+ ]]; then
            in_directory=true
            current_directory=$line
            line_buffer="$line"
            continue
        fi

        # Se siamo in una sezione Directory
        if [ "$in_directory" = true ]; then
            # Se troviamo la fine della sezione Directory
            if [[ $line =~ ^[[:space:]]*\</Directory\> ]]; then
                in_directory=false
                # Se non abbiamo trovato LimitExcept, lo aggiungiamo
                if ! echo "$line_buffer" | grep -q "<LimitExcept"; then
                    echo "$line_buffer" >> "$temp_file"
                    echo "    <LimitExcept GET POST HEAD>" >> "$temp_file"
                    echo "        Require all denied" >> "$temp_file"
                    echo "    </LimitExcept>" >> "$temp_file"
                    echo "$line" >> "$temp_file"
                    changes_made=true
                    echo -e "${GREEN}✓ Aggiunta configurazione LimitExcept in $current_directory${NC}"
                else
                    echo "$line_buffer" >> "$temp_file"
                    echo "$line" >> "$temp_file"
                fi
                line_buffer=""
            else
                # Accumula le linee della sezione Directory
                line_buffer="$line_buffer"$'\n'"$line"
            fi
        else
            echo "$line" >> "$temp_file"
        fi
    done < "$file"

    # Se sono state fatte modifiche, applica i cambiamenti
    if [ "$changes_made" = true ]; then
        mv "$temp_file" "$file"
        return 0
    else
        rm "$temp_file"
        return 1
    fi
}

print_section "Verifica CIS 5.7: Restrizione Metodi HTTP in Sezioni Directory"

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

# Array dei metodi HTTP permessi
ALLOWED_METHODS=("GET" "POST" "HEAD")

# Array per memorizzare i file con sezioni Directory
declare -a config_files=()

print_section "Ricerca file di configurazione con sezioni Directory"

# Trova tutti i file di configurazione con sezioni Directory
while IFS= read -r file; do
    if grep -q "<Directory" "$file"; then
        config_files+=("$file")
        echo "Trovato file con sezioni Directory: $file"
    fi
done < <(find "$APACHE_CONFIG_DIR" -type f -name "*.conf")

if [ ${#config_files[@]} -eq 0 ]; then
    echo -e "${RED}Nessuna sezione Directory trovata nei file di configurazione${NC}"
    exit 1
fi

# Chiedi conferma per la remediation
#echo -e "\n${YELLOW}Vuoi procedere con la verifica e remediation delle sezioni Directory? (s/n)${NC}"
#read -r risposta

if [[ "$risposta" =~ ^[Ss]$ ]]; then
    print_section "Esecuzione Remediation"
    
    # Backup dei file di configurazione
    timestamp=$(date +%Y%m%d_%H%M%S)_CIS_5.7
    backup_dir="/root/apache_methods_backup_$timestamp"
    mkdir -p "$backup_dir"
    
    echo "Creazione backup in $backup_dir..."
    cp -r "$APACHE_CONFIG_DIR" "$backup_dir/"
    
    # Processa ogni file di configurazione
    for config_file in "${config_files[@]}"; do
        echo -e "\nProcessing file: $config_file"
        if modify_directory_section "$config_file"; then
            echo -e "${GREEN}✓ Modifiche applicate a $config_file${NC}"
        else
            echo -e "${YELLOW}Nessuna modifica necessaria in $config_file${NC}"
        fi
    done
    
    # Verifica la configurazione di Apache
    echo -e "\n${YELLOW}Verifica della configurazione di Apache...${NC}"
    if httpd -t 2>/dev/null || apache2ctl -t 2>/dev/null; then
        echo -e "${GREEN}✓ Configurazione di Apache valida${NC}"
        
        # Riavvio di Apache
        echo -e "\n${YELLOW}Riavvio di Apache...${NC}"
        if systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null; then
            echo -e "${GREEN}✓ Apache riavviato con successo${NC}"
            
            # Test pratici
            echo -e "\n${YELLOW}Esecuzione test dei metodi HTTP...${NC}"
            
            # Test dei metodi permessi
            for method in "${ALLOWED_METHODS[@]}"; do
                response=$(curl -X "$method" -s -o /dev/null -w "%{http_code}" http://localhost/)
                if [ "$response" != "403" ]; then
                    echo -e "${GREEN}✓ Metodo $method permesso${NC}"
                else
                    echo -e "${RED}✗ Metodo $method bloccato inaspettatamente${NC}"
                fi
            done
            
            # Test dei metodi non permessi
            #for method in "PUT" "DELETE" "TRACE" "OPTIONS"; do
            #    response=$(curl -X "$method" -s -o /dev/null -w "%{http_code}" http://localhost/)
            #    if [ "$response" = "403" ]; then
            #        echo -e "${GREEN}✓ Metodo $method correttamente bloccato${NC}"
            #    else
            #        echo -e "${RED}✗ Metodo $method non bloccato correttamente${NC}"
            #    fi
            #done
        else
            echo -e "${RED}✗ Errore durante il riavvio di Apache${NC}"
        fi
    else
        echo -e "${RED}✗ Errore nella configurazione di Apache${NC}"
        echo -e "${YELLOW}Ripristino del backup...${NC}"
        
        # Ripristina dal backup
        cp -r "$backup_dir"/* "$APACHE_CONFIG_DIR/"
        
        systemctl restart httpd 2>/dev/null || systemctl restart apache2 2>/dev/null
        echo -e "${GREEN}Backup ripristinato${NC}"
    fi
else
    echo -e "${YELLOW}Operazione annullata dall'utente${NC}"
fi

# Riepilogo finale
print_section "Riepilogo Finale"
echo "1. File di configurazione processati:"
for file in "${config_files[@]}"; do
    echo "   - $file"
done
echo "2. Metodi HTTP permessi: ${ALLOWED_METHODS[*]}"
if [ -d "$backup_dir" ]; then
    echo "3. Backup salvato in: $backup_dir"
fi

echo -e "\n${BLUE}Nota: La corretta limitazione dei metodi HTTP nelle sezioni Directory garantisce che:${NC}"
echo -e "${BLUE}- Solo i metodi essenziali siano permessi in specifiche directory${NC}"
echo -e "${BLUE}- Si applichi una sicurezza granulare a livello di directory${NC}"
echo -e "${BLUE}- Si prevengano metodi potenzialmente pericolosi in aree sensibili${NC}"
echo -e "${BLUE}- Si migliori la sicurezza complessiva del server web${NC}"
