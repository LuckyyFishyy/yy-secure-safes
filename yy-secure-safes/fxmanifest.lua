-- By using this script, you agree to the EULA provided by LuckyyFishyy

fx_version 'cerulean'
game 'gta5'

author 'LuckyyFishyy'
description ' Script for QBcore'
version '1.0.0'

dependencies {
    'qb-core',
    'ox_inventory',
    'oxmysql'
}

-- Scripts
shared_script 'shared/*.lua'
client_script 'client/*.lua'
server_script 'server/*.lua'

-- UI
ui_page 'html/index.html'

files {
    'html/index.html',
    'html/script.js',
    'html/style.css',
    'html/settings-menu.html',
    'html/sounds/*.ogg',
    'html/sounds/*.mp3'
}

export 'useSafe'
server_export 'useSafe'

