// www/speech.js — Background Web Speech API for ggplot Voice Copilot (conversational edition)
// ─────────────────────────────────────────────────────────────────────────────────────────────
// Voice works in the background — no visible mic button.
// Press SPACE (when not focused on a text field) to start/stop recording.
// Recognised speech is sent to the shinychat input via voice_text → server →
// update_chat_user_input(), which populates and auto-submits the chat box.

$(document).on("shiny:connected", function () {
  "use strict";

  console.log("[speech.js] Shiny connected, initializing...");

  // ====== Custom message handlers ======

  Shiny.addCustomMessageHandler("update_journal_instructions", function (content) {
    showStatus("\uD83D\uDCD4 Journal skills loaded (" + (content ? content.length : 0) + " chars)", 3000);
    console.log("[speech.js] Journal instructions updated");
  });

  // ====== Thumbnail click — event delegation (works even over plotOutput <img>) ======
  // Uses jQuery .on() delegation so clicks from any child element (img, label, etc.)
  // bubble up and are caught here reliably.
  $(document).on("click", ".thumb-item", function () {
    var plotName = $(this).data("plotname");
    if (plotName) {
      console.log("[speech.js] Thumbnail clicked:", plotName);
      Shiny.setInputValue("selected_plot", plotName, { priority: "event" });
    }
  });

  Shiny.addCustomMessageHandler("updateActiveThumb", function (activeName) {
    // Toggle .active class on thumb items without re-rendering the panel
    $(".thumb-item").each(function () {
      if ($(this).data("plotname") === activeName) {
        $(this).addClass("active");
      } else {
        $(this).removeClass("active");
      }
    });
  });

  Shiny.addCustomMessageHandler("copy_to_clipboard", function (text) {
    if (navigator.clipboard) {
      navigator.clipboard.writeText(text).then(function () {
        console.log("[speech.js] Code copied to clipboard \u2713");
      });
    }
  });

  // ====== Status indicator ======
  // Shows a brief message in the #voice_interim div, then auto-hides.
  function showStatus(msg, durationMs) {
    var el = document.getElementById("voice_interim");
    if (!el) return;
    el.textContent   = msg;
    el.style.display = "block";
    clearTimeout(el._hideTimer);
    if (durationMs) {
      el._hideTimer = setTimeout(function () {
        el.style.display = "none";
        el.textContent   = "";
      }, durationMs);
    }
  }

  function clearStatus() {
    var el = document.getElementById("voice_interim");
    if (el) { el.style.display = "none"; el.textContent = ""; }
  }

  // ====== Send command to Shiny ======
  function sendCommand(command) {
    if (!command || !command.trim()) return;
    console.log("[speech.js] Sending voice command:", command);
    // Timestamp ensures Shiny always sees this as a new value even for repeated text
    Shiny.setInputValue("voice_text", {
      text:      command.trim(),
      timestamp: Date.now()
    });
  }

  // ====== Web Speech API ======
  var SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;

  if (!SpeechRecognition) {
    console.warn("[speech.js] Web Speech API NOT supported in this browser.");
    Shiny.setInputValue("voice_support", false);
    var hint = document.getElementById("voice_hint");
    if (hint) {
      hint.innerHTML = '<i class="fa fa-exclamation-triangle" style="color:#E74C3C;"></i> Voice not supported \u2014 open in Chrome or Edge';
    }
    return;
  }

  console.log("[speech.js] Web Speech API available \u2713");
  Shiny.setInputValue("voice_support", true);

  var isListening     = false;
  var finalTranscript = "";
  var recognition     = null;

  // Update the voice hint pill to show listening state
  function setHintState(listening) {
    var hint = document.getElementById("voice_hint");
    if (!hint) return;
    if (listening) {
      hint.innerHTML = '<i class="fa fa-microphone" style="color:#E74C3C; animation:pulse-icon 1s infinite;"></i> <strong>Listening\u2026</strong> press <kbd>Space</kbd> to stop';
      hint.classList.add("listening");
    } else {
      hint.innerHTML = '<i class="fa fa-microphone" style="color:#18BC9C;"></i> Press <kbd>Space</kbd> to speak \u2014 voice is sent to the chat';
      hint.classList.remove("listening");
    }
  }

  function createRecognition() {
    if (!SpeechRecognition) return null;
    var rec = new SpeechRecognition();
    rec.continuous      = false;
    rec.interimResults  = true;
    rec.lang            = "en-US";
    rec.maxAlternatives = 1;

    rec.onstart = function () {
      console.log("[speech.js] Recognition started");
      isListening     = true;
      finalTranscript = "";
      setHintState(true);
      showStatus("\uD83C\uDF99\uFE0F Listening\u2026");
    };

    rec.onresult = function (event) {
      var interim = "";
      finalTranscript = ""; // Recalculate completely to avoid Chrome result duplication bugs
      for (var i = event.resultIndex; i < event.results.length; i++) {
        var t = event.results[i][0].transcript;
        if (event.results[i].isFinal) finalTranscript += t;
        else interim += t;
      }
      showStatus(interim || finalTranscript);
    };

    rec.onend = function () {
      console.log("[speech.js] Recognition ended. Final:", finalTranscript);
      isListening = false;
      setHintState(false);
      var toSend = finalTranscript.trim();
      finalTranscript = "";   // clear immediately
      if (toSend) {
        showStatus('\uD83C\uDF99\uFE0F "' + toSend + '"', 4000);
        sendCommand(toSend);
      } else {
        showStatus("No speech detected.", 2500);
      }
    };

    rec.onerror = function (event) {
      console.error("[speech.js] Recognition error:", event.error);
      isListening = false;
      setHintState(false);
      var msg = "\u26A0\uFE0F Error: " + event.error;
      if (event.error === "not-allowed") {
        msg = "\u26A0\uFE0F Microphone access denied \u2014 allow microphone in browser settings.";
      } else if (event.error === "no-speech") {
        msg = "No speech detected.";
      } else if (event.error === "network") {
        msg = "\u26A0\uFE0F Network error \u2014 Web Speech API requires internet.";
      }
      showStatus(msg, 4000);
    };
    return rec;
  }

  function toggleRecognition() {
    if (isListening && recognition) {
      console.log("[speech.js] Stopping recognition\u2026");
      recognition.stop();
    } else {
      console.log("[speech.js] Starting recognition\u2026");
      finalTranscript = "";
      recognition = createRecognition();
      if (!recognition) return;
      try { recognition.start(); }
      catch (err) { showStatus("\u26A0\uFE0F Could not start recognition. Try again.", 3000); }
    }
  }

  // ====== Spacebar to toggle voice (only when not typing in a text field) ======
  $(document).on("keydown", function (e) {
    // Ignore space if user is focused on <input>, <textarea>, or contenteditable
    var tag = document.activeElement ? document.activeElement.tagName.toLowerCase() : "";
    var isEditable = (tag === "input" || tag === "textarea" || tag === "select" ||
                      (document.activeElement && document.activeElement.isContentEditable));
    if (isEditable) return;

    if (e.key === " " || e.keyCode === 32) {
      e.preventDefault();
      toggleRecognition();
    }
  });

  // ====== Programmatic control from Shiny ======
  Shiny.addCustomMessageHandler("start_listening", function (_) {
    if (!isListening) try { recognition.start(); } catch (_) { /* ignore */ }
  });
  Shiny.addCustomMessageHandler("stop_listening", function (_) {
    if (isListening) recognition.stop();
  });

  setHintState(false);
  console.log("[speech.js] Voice (background spacebar mode) initialized \u2713");
});
