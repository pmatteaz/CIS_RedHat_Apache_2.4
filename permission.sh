#!/bin/bash

# Colori per output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Funzione per mostrare l'uso dello script
usage() {
    echo "Uso: $0 [-b|-r] directory [file_backup]"
    echo "  -b: backup dei permessi"
    echo "  -r: ripristino dei permessi"
    echo "  directory: directory da processare"
    echo "  file_backup: file dove salvare/da cui ripristinare i permessi (opzionale)"
    exit 1
}

# Verifica argomenti
if [ "$#" -lt 2 ]; then
    usage
fi

# Parse delle opzioni
OPERATION=""
case "$1" in
    -b) OPERATION="backup" ;;
    -r) OPERATION="restore" ;;
    *) usage ;;
esac

# Directory da processare
DIRECTORY="$2"
if [ ! -d "$DIRECTORY" ]; then
    echo -e "${RED}Errore: $DIRECTORY non è una directory valida${NC}"
    exit 1
fi

# Nome del file di backup (default o specificato)
BACKUP_FILE="${3:-permissions_backup_$(date +%Y%m%d_%H%M%S).txt}"

# Funzione per il backup dei permessi
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

# Esegui l'operazione richiesta
case "$OPERATION" in
    "backup")
        do_backup "$DIRECTORY" "$BACKUP_FILE"
        ;;
    "restore")
        do_restore "$DIRECTORY" "$BACKUP_FILE"
        ;;
esac
