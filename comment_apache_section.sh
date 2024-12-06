#!/bin/bash

# Funzione per commentare una sezione in un file di configurazione Apache
comment_apache_section() {
    local file_path="$1"
    local section_name="$2"
    
    # Verifica che il file esista
    if [ ! -f "$file_path" ]; then
        echo "Errore: Il file $file_path non esiste"
        return 1
    }
    
    # Crea un backup del file
    cp "$file_path" "${file_path}.bak"
    
    # Variabili per tenere traccia dello stato
    local in_section=0
    local nesting_level=0
    local tmp_file=$(mktemp)
    
    # Elabora il file riga per riga
    while IFS= read -r line; do
        # Rimuovi gli spazi iniziali e finali per il confronto
        local stripped_line=$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
        
        # Controlla l'apertura della sezione
        if echo "$stripped_line" | grep -E "^<${section_name}(\s|>)" >/dev/null && ! echo "$stripped_line" | grep -E "^#" >/dev/null; then
            if [ $nesting_level -eq 0 ]; then
                in_section=1
            fi
            nesting_level=$((nesting_level + 1))
        fi
        
        # Se siamo nella sezione target e la riga non è già commentata, commenta
        if [ $in_section -eq 1 ] && ! echo "$line" | grep -E "^#" >/dev/null; then
            echo "#$line" >> "$tmp_file"
        else
            echo "$line" >> "$tmp_file"
        fi
        
        # Controlla la chiusura della sezione
        if echo "$stripped_line" | grep -E "^</${section_name}>" >/dev/null && ! echo "$stripped_line" | grep -E "^#" >/dev/null; then
            nesting_level=$((nesting_level - 1))
            if [ $nesting_level -eq 0 ]; then
                in_section=0
            fi
        fi
    done < "$file_path"
    
    # Sposta il file temporaneo al posto dell'originale
    mv "$tmp_file" "$file_path"
    
    # Imposta i permessi corretti
    chmod --reference="${file_path}.bak" "$file_path"
    
    echo "Operazione completata. Backup salvato in ${file_path}.bak"
    return 0
}

# Funzione per mostrare l'uso dello script
show_usage() {
    echo "Uso: $0 <file_path> <section_name>"
    echo "Esempio: $0 /etc/apache2/apache2.conf Directory"
    echo ""
    echo "Lo script commenterà tutte le righe nella sezione specificata."
    echo "Verrà creato un backup del file originale con estensione .bak"
}

# Verifica degli argomenti
if [ $# -ne 2 ]; then
    show_usage
    exit 1
fi

# Esegui la funzione principale
comment_apache_section "$1" "$2"
exit $?
