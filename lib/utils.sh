set -e
set -o pipefail

LC_ALL="C"
LANG="C"
LANGUAGE="C"

CROSS_COMPILE="aarch64-linux-gnu-"

EXIT_SUCCESS=0
EXIT_UNKNOWN_OPTION=1
EXIT_TOO_FEW_ARGUMENTS=2
EXIT_UNSUPPORTED_OPTION=3

error() {
    case "$1" in
        $EXIT_SUCCESS)
            ;;
        $EXIT_UNKNOWN_OPTION)
            echo "${FUNCNAME[1]}->${FUNCNAME[0]}: Unknown option: '$2'." >&2
            ;;
        $EXIT_TOO_FEW_ARGUMENTS)
            echo "${FUNCNAME[1]}->${FUNCNAME[0]}: Too few arguments." >&2
            ;;
        $EXIT_UNSUPPORTED_OPTION)
            echo "${FUNCNAME[1]}->${FUNCNAME[0]}: Option '$2' is not supported." >&2
            ;;
        *)
            echo "${FUNCNAME[1]}->${FUNCNAME[0]}: Unknown exit code." >&2
            ;;
    esac
    
    exit "$1"
}

printf_array() {
    local FORMAT="$1"
    shift
    local ARRAY=("$@")

    if [[ $FORMAT == "json" ]]
    then
        jq --compact-output --null-input '$ARGS.positional' --args -- "${ARRAY[@]}"
    else
        for i in ${ARRAY[@]}
        do
            printf "$FORMAT" "$i"
        done
    fi
}

in_array() {
    local ITEM="$1"
    shift
    local ARRAY=("$@")
    if [[ " ${ARRAY[*]} " =~ " $ITEM " ]]
    then
        true
    else
        false
    fi
}

git_source() {
    local git_url="$1"
    __CUSTOM_SOURCE_FOLDER="$(basename $git_url)"
    __CUSTOM_SOURCE_FOLDER="${__CUSTOM_SOURCE_FOLDER%.*}"

    if ! [[ -e "$SRC_DIR/$__CUSTOM_SOURCE_FOLDER" ]]
    then
        local git_branch="$2"
        if [[ -n $git_branch ]]
        then
            git_branch="--branch $git_branch"
        fi

        git clone --depth 1 $git_branch "$git_url" "$SRC_DIR/$__CUSTOM_SOURCE_FOLDER"
    else
        unset __CUSTOM_SOURCE_FOLDER
    fi
}

git_am() {
    if [[ -n "$__CUSTOM_SOURCE_FOLDER" ]]
    then
        local patch="$(realpath "$1")"
        pushd "$SRC_DIR/$__CUSTOM_SOURCE_FOLDER"
        git am "$patch"
        popd
    fi
}

prepare_source() {
    local TARGET="$1"
    local SRC_DIR="$SCRIPT_DIR/.src"
    TARGET_DIR="$SRC_DIR/$TARGET"
    local FORK_DIR="$SCRIPT_DIR/$TARGET/$FORK"

    mkdir -p "$TARGET_DIR"

    if [[ $NO_PREPARE_SOURCE == "yes" ]]
    then
        return
    fi

    pushd "$TARGET_DIR"

        git init
        [[ -z $(git config --get user.name) ]] && git config user.name "bsp"
        [[ -z $(git config --get user.email) ]] && git config user.email "bsp@radxa.com"
        git am --abort && true
        [[ -n $(git status -s) ]] && git reset --hard HEAD

        local ORIGIN=$(sha1sum <(echo "$BSP_GIT") | cut -d' ' -f1)
        git remote add $ORIGIN $BSP_GIT 2>/dev/null && true

        if [[ -n $BSP_COMMIT ]]
        then
            git fetch --depth 1 $ORIGIN $BSP_COMMIT
            git checkout $BSP_COMMIT
            git update-ref refs/tags/$BSP_COMMIT $BSP_COMMIT
        elif [[ -n $BSP_BRANCH ]]
        then
            # Tag is more precise than branch and should be preferred.
            # However, since we are defaulting with upstream Linux,
            # we will always have non empty $BSP_TAG.
            # As such check $BSP_BRANCH first.
            git fetch --depth 1 $ORIGIN $BSP_BRANCH
            git checkout $BSP_BRANCH
        elif [[ -n $BSP_TAG ]]
        then
            git fetch --depth 1 $ORIGIN tag $BSP_TAG
            git checkout tags/$BSP_TAG
        fi

        git reset --hard FETCH_HEAD
        git clean -ffd

        for d in $(find -L $FORK_DIR -type d | sort -r)
        do
            shopt -s nullglob
            for f in $d/*.sh
            do
                if [[ $(type -t custom_source_action) == function ]]
                then
                    unset -f custom_source_action
                fi

                source $f

                if [[ $(type -t custom_source_action) == function ]]
                then
                    echo "Running custom_source_action from $f"
                    
                    pushd "$(dirname "$f")"
                    custom_source_action "$SCRIPT_DIR" "$TARGET_DIR"
                    popd
                fi
            done
            shopt -u nullglob
        done

        for d in $(find -L $FORK_DIR -type d | sort)
        do
            if ls $d/*.patch &>/dev/null
            then
                git am --reject --whitespace=fix $(ls $d/*.patch)
            fi
        done
        
    popd
}

kconfig() {
    local mode="config"
    if [[ $1 == "-v" ]]
    then
        mode="verify"
        shift
    fi
    local file="$1"

    while IFS="" read -r k || [ -n "$k" ]
    do
        local config=
        local option=
        local switch=
        if grep -q "^# CONFIG_.* is not set$" <<< $k
        then
            config=$(cut -d ' ' -f 2 <<< $k)
            switch="--undefine"
        elif grep -q "^CONFIG_.*=[ynm]$" <<< $k
        then
            config=$(cut -d '=' -f 1 <<< $k)
            case "$(cut -d'=' -f 2 <<< $k)" in
                y)
                    switch="--enable"
                    ;;
                n)
                    switch="--disable"
                    ;;
                m)
                    switch="--module"
                    ;;
            esac
        elif grep -q "^CONFIG_.*=\".*\"$" <<< $k
        then
            IFS='=' read -r config option <<< $k
            switch="--set-val"
        elif grep -q "^CONFIG_.*=.*$" <<< $k
        then
            IFS='=' read -r config option <<< $k
            switch="--set-val"
        elif grep -q "^#" <<< $k
        then
            continue
        elif [[ -z "$k" ]]
        then
            continue
        else
            error $EXIT_UNKNOWN_OPTION "$k"
        fi
        case $mode in
            config)
                "$SCRIPT_DIR/common/config" --file "$TARGET_DIR/.config" $switch $config "$option"
                ;;
            verify)
                if ! grep -q "$k" "$TARGET_DIR/.config"
                then
                    if ! grep -q "^# CONFIG_.* is not set$" <<< $k || grep -q "$(cut -d ' ' -f 2 <<< $k)" "$TARGET_DIR/.config"
                    then
                        echo "kconfig: Mismatch: $k" >&2
                    fi
                fi
                ;;
        esac
    done < "$file"
}

apply_kconfig() {
    if [[ -e "$1" ]]
    then
        tee -a "$SCRIPT_DIR/.src/build.log" <<< "Apply kconfig from $1"
        kconfig "$1"
        kconfig -v "$1" | tee -a "$SCRIPT_DIR/.src/build.log"
    fi
}

get_soc_family() {
    case "$1" in
        rk*)
            echo rockchip
            ;;
        s905y2|a311d)
            echo amlogic
            ;;
        *)
            error $EXIT_UNSUPPORTED_OPTION "$1"
            ;;
    esac
}

load_edition() {
    if ! source "$SCRIPT_DIR/lib/$1.sh" 2>/dev/null
    then
        error $EXIT_UNKNOWN_OPTION "$1"
    fi
    TARGET=$1
    bsp_reset

    if ! source "$SCRIPT_DIR/$TARGET/$2/fork.conf" 2>/dev/null
    then
        error $EXIT_UNKNOWN_OPTION "$2"
    fi
    FORK=$2
}