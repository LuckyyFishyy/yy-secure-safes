let current = ''
let mode = 'enter'
let safeId = null

const app = document.getElementById('app')
const display = document.getElementById('display')
const settingsMenu = document.getElementById('settingsMenu')
const placementHelp = document.getElementById('placementHelp')
const keyOption = document.getElementById('keyOption')
const upgradeOption = document.getElementById('upgradeOption')
const removeUpgradeOption = document.getElementById('removeUpgradeOption')
const sealOption = document.getElementById('sealOption')
const antiDrillOption = document.getElementById('antiDrillOption')
const alarmOption = document.getElementById('alarmOption')
const removeAlarmOption = document.getElementById('removeAlarmOption')
let selectedMenuIndex = 0
let menuActive = false
let currentSafeId = null
const alarmAudios = {}

function playSound(name, volume) {
  if (!name) return
  const base = `sounds/${name}`
  const vol = typeof volume === 'number' ? Math.min(Math.max(volume, 0), 1) : 0.35
  const audio = new Audio(`${base}.ogg`)
  audio.volume = vol
  audio.addEventListener('error', () => {
    const fallback = new Audio(`${base}.mp3`)
    fallback.volume = vol
    fallback.play().catch(() => {})
  }, { once: true })
  audio.play().catch(() => {})
}

function setDisplay() {
  display.textContent = current.padEnd(4, '-')
}

function startAlarmAudio(safeId, sound, volume) {
  const key = String(safeId)
  const existing = alarmAudios[key]
  if (existing && existing.audio) {
    existing.audio.volume = typeof volume === 'number' ? volume : existing.audio.volume
    if (existing.audio.paused) existing.audio.play().catch(() => {})
    return
  }
  const base = `sounds/${sound}`
  const audio = new Audio(`${base}.ogg`)
  audio.loop = true
  audio.volume = typeof volume === 'number' ? volume : 0.35
  audio.addEventListener('error', () => {
    const fallback = new Audio(`${base}.mp3`)
    fallback.loop = true
    fallback.volume = typeof volume === 'number' ? volume : 0.35
    alarmAudios[key] = { audio: fallback }
    fallback.play().catch(() => {})
  }, { once: true })
  alarmAudios[key] = { audio }
  audio.play().catch(() => {})
}

function setAlarmVolume(safeId, volume) {
  const key = String(safeId)
  const entry = alarmAudios[key]
  if (!entry || !entry.audio) return
  if (typeof volume === 'number') {
    entry.audio.volume = Math.min(Math.max(volume, 0), 1)
  }
}

function stopAlarmAudio(safeId) {
  const key = String(safeId)
  const entry = alarmAudios[key]
  if (!entry || !entry.audio) return
  entry.audio.pause()
  entry.audio.currentTime = 0
  delete alarmAudios[key]
}

window.addEventListener('message', (event) => {
  const data = event.data
  if (!data) return
  
  if (data.action === 'open') {
    mode = data.mode || 'enter'
    safeId = data.safeId
    current = ''
    setDisplay()
    if (placementHelp) placementHelp.classList.add('hidden')
    app.classList.remove('hidden')
  }
  
  if (data.action === 'close') {
    app.classList.add('hidden')
  }

  if (data.action === 'showPlacementHelp') {
    if (placementHelp) placementHelp.classList.remove('hidden')
  }

  if (data.action === 'hidePlacementHelp') {
    if (placementHelp) placementHelp.classList.add('hidden')
  }

  if (data.action === 'playSound' && data.sound) {
    playSound(data.sound, data.volume)
  }

  if (data.action === 'startAlarm' && data.sound && data.safeId !== null) {
    startAlarmAudio(data.safeId, data.sound, data.volume)
  }

  if (data.action === 'setAlarmVolume' && data.safeId !== null) {
    setAlarmVolume(data.safeId, data.volume)
  }

  if (data.action === 'stopAlarm' && data.safeId !== null) {
    stopAlarmAudio(data.safeId)
  }
  
  if (data.action === 'openSettingsMenu') {
    currentSafeId = data.safeId
    menuActive = true
    selectedMenuIndex = 0
    if (keyOption) {
      if (data.enableKeyCraft) {
        keyOption.classList.remove('hidden')
      } else {
        keyOption.classList.add('hidden')
      }
    }
    if (upgradeOption) {
      if (data.enableUpgrades) {
        upgradeOption.classList.remove('hidden')
      } else {
        upgradeOption.classList.add('hidden')
      }
    }
    if (removeUpgradeOption) {
      if (data.enableUpgrades && data.canRemoveUpgrade) {
        removeUpgradeOption.classList.remove('hidden')
      } else {
        removeUpgradeOption.classList.add('hidden')
      }
    }
    if (sealOption) {
      if (data.enableVaultSeal && data.canApplyVaultSeal) {
        sealOption.classList.remove('hidden')
      } else {
        sealOption.classList.add('hidden')
      }
    }
    if (antiDrillOption) {
      if (data.enableAntiDrill && data.canApplyAntiDrill) {
        antiDrillOption.classList.remove('hidden')
      } else {
        antiDrillOption.classList.add('hidden')
      }
    }
    if (alarmOption) {
      if (data.enableAlarm && data.canInstallAlarm) {
        alarmOption.classList.remove('hidden')
      } else {
        alarmOption.classList.add('hidden')
      }
    }
    if (removeAlarmOption) {
      if (data.enableAlarm && data.canRemoveAlarm) {
        removeAlarmOption.classList.remove('hidden')
      } else {
        removeAlarmOption.classList.add('hidden')
      }
    }
    settingsMenu.classList.add('active')
    updateMenuSelection()
  }
  
  if (data.action === 'closeSettingsMenu') {
    menuActive = false
    settingsMenu.classList.remove('active')
    currentSafeId = null
  }
})

// Passcode Panel Handlers
Array.from(document.getElementsByClassName('num')).forEach(btn => {
  btn.addEventListener('click', () => {
  if (current.length >= 4) return
    current += btn.textContent
    setDisplay()
  })
})

document.getElementById('back').addEventListener('click', () => {
  current = current.slice(0, -1)
  setDisplay()
})

document.getElementById('enter').addEventListener('click', () => {
  // Basic client-side validation: numeric only and length 4
  if (!/^[0-9]+$/.test(current)) {
    return
  }
  if (current.length !== 4) {
    return
  }

  // submit to lua
  fetch('https://yy-secure-safes/submitPasscode', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json; charset=UTF-8',
    },
    body: JSON.stringify({ code: current, mode: mode, safeId: safeId })
  }).then(resp => resp.json()).then(() => {
    app.classList.add('hidden')
  })
})

document.getElementById('cancel').addEventListener('click', () => {
  fetch('https://yy-secure-safes/close', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify({})
  }).then(() => {
    app.classList.add('hidden')
  })
})

// Settings Menu Handlers
function updateMenuSelection() {
  const options = document.querySelectorAll('.menu-option')
  options.forEach((option, index) => {
    if (index === selectedMenuIndex) {
      option.classList.add('selected')
    } else {
      option.classList.remove('selected')
    }
  })
}

document.querySelectorAll('.menu-option').forEach((option, index) => {
  option.addEventListener('click', () => {
    selectedMenuIndex = index
    updateMenuSelection()
    selectMenuOption()
  })
})

function selectMenuOption() {
  const options = document.querySelectorAll('.menu-option')
  const action = options[selectedMenuIndex].dataset.action
  
  fetch('https://yy-secure-safes/settingsMenuAction', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json; charset=UTF-8',
    },
    body: JSON.stringify({
      action: action,
      safeId: currentSafeId
    })
  }).then(() => {
    menuActive = false
    settingsMenu.classList.remove('active')
  })
}

document.addEventListener('keydown', (event) => {
  if (!menuActive) return
  
  const options = document.querySelectorAll('.menu-option')
  
  if (event.key === 'ArrowUp') {
    selectedMenuIndex = (selectedMenuIndex - 1 + options.length) % options.length
    updateMenuSelection()
  } else if (event.key === 'ArrowDown') {
    selectedMenuIndex = (selectedMenuIndex + 1) % options.length
    updateMenuSelection()
  } else if (event.key === 'Enter') {
    selectMenuOption()
  } else if (event.key === 'Escape') {
    menuActive = false
    settingsMenu.classList.remove('active')
    fetch('https://yy-secure-safes/closeSettingsMenu', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify({})
    })
  }
})

setDisplay()
