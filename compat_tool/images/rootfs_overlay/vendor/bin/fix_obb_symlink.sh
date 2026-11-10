#!/system/bin/sh

APP_ID=$1

APP_PATH="$(pm path "$APP_ID" | sed -n 's|^package:\(.*\)/base\.apk$|\1|p')"
[[ -n "$APP_PATH" ]] || exit 1

local OBB_INNER_PATH="${APP_PATH}"

# If the obb dir is empty we use the main directory
rmdir "${OBB_INNER_PATH}/obb" || true

if [[ -d "${OBB_INNER_PATH}/obb" ]]; then
    OBB_INNER_PATH="${APP_PATH}/obb"
fi
OBB_LINK="/data/media/0/Android/obb/${APP_ID}"
if [[ -L "$OBB_LINK" ]]; then
    [[ "$(readlink "$OBB_LINK")" == "$OBB_INNER_PATH" ]] && exit 0
    echo "Existing OBB link preserved: $OBB_LINK" >&2
    exit 1
elif [[ -e "$OBB_LINK" ]]; then
    echo "Existing OBB data preserved: $OBB_LINK" >&2
    exit 1
fi
ln -sv "$OBB_INNER_PATH" "$OBB_LINK"
