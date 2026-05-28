(function () {
  let peerConnection = null;
  let dataChannel = null;
  let micStream = null;
  let audioEl = null;
  let emitToFlutter = null;
  let aiTurnTranscript = "";
  let targetLanguage = "English";
  let providerLanguage = "Thai";
  let goalRecognition = null;
  let goalSpeechActive = false;
  let manualStop = false;
  let activeGoal = "";
  let activeOnEvent = null;
  let reconnectAttempts = 0;
  let reconnectTimer = null;
  const defaultBackendBaseUrl = "https://travelwithmeai-server.onrender.com";
  const customDomainBackendBaseUrl = "https://api.travelwithmeai.com";
  const requestTimeoutMs = 15000;
  const maxReconnectAttempts = 1;

  function backendBaseUrl() {
    const configured =
      window.TRAVELWITHMEAI_API_BASE_URL ||
      document.querySelector('meta[name="travelwithmeai-api-base-url"]')?.content ||
      defaultBackendBaseUrl;
    return String(configured).replace(/\/+$/, "");
  }

  function backendUrl(path) {
    return `${backendBaseUrl()}${path.startsWith("/") ? path : `/${path}`}`;
  }

  function emit(type, payload = {}) {
    if (emitToFlutter) {
      emitToFlutter(JSON.stringify({ type, ...payload }));
    }
  }

  function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
  }

  async function fetchWithTimeout(url, options = {}, timeoutMs = requestTimeoutMs) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    try {
      return await fetch(url, { ...options, signal: controller.signal });
    } finally {
      clearTimeout(timeout);
    }
  }

  async function fetchJsonWithRetry(url, options = {}, retries = 2) {
    let lastError = null;

    for (let attempt = 0; attempt <= retries; attempt += 1) {
      try {
        const response = await fetchWithTimeout(url, options);
        const data = await response.json().catch(() => ({}));

        if (!response.ok && attempt < retries && (response.status === 429 || response.status >= 500)) {
          await sleep(300 * (attempt + 1));
          continue;
        }

        return { response, data };
      } catch (error) {
        lastError = error;
        if (attempt >= retries) break;
        await sleep(300 * (attempt + 1));
      }
    }

    throw lastError || new Error("Network request failed.");
  }

  async function requestMicrophoneStream() {
    if (navigator.permissions?.query) {
      let permission = null;
      try {
        permission = await navigator.permissions.query({ name: "microphone" });
      } catch {
        // Some browsers do not expose microphone permission state. getUserMedia will show the prompt.
      }
      if (permission?.state === "denied") {
        throw new Error("Microphone permission is blocked. Enable it in browser settings and try again.");
      }
    }

    return navigator.mediaDevices.getUserMedia({
      audio: {
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true
      }
    });
  }

  function scheduleReconnect() {
    if (manualStop || reconnectAttempts >= maxReconnectAttempts || !activeGoal || !activeOnEvent) return;

    reconnectAttempts += 1;
    clearTimeout(reconnectTimer);
    emit("status", { message: "Disconnected. Reconnecting..." });
    reconnectTimer = setTimeout(() => {
      window.startFlutterRealtimeNegotiator(activeGoal, activeOnEvent, { isReconnect: true });
    }, 900);
  }

  function parseTargetLanguage(goal) {
    const match = String(goal || "").match(/User translation language:\s*([^\n]+)/i);
    return match ? match[1].trim() : "English";
  }

  function parseProviderLanguage(goal) {
    const match = String(goal || "").match(/Provider language:\s*([^\n]+)/i);
    return match ? match[1].trim() : "Thai";
  }

  function parseGoalField(goal, fieldName) {
    const escaped = fieldName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    const match = String(goal || "").match(new RegExp(`${escaped}:\\s*([^\\n]+)`, "i"));
    return match ? match[1].trim() : "";
  }

  function userRequestSummary(goal) {
    const activity = parseGoalField(goal, "Activity") || "this service";
    const people = parseGoalField(goal, "People");
    return people ? `${activity} for ${people} people` : activity;
  }

  function negotiationInstructions(goal) {
    const request = userRequestSummary(goal);
    return [
      `Begin in polite, natural ${providerLanguage}.`,
      `Speak only ${providerLanguage} to the service provider unless the user changes the provider language.`,
      `Your first message must be short: greet the provider, say you are helping your friend communicate, say they want ${request}, then ask the price.`,
      "Use normal human wording like: Hi, I am helping my friend communicate. How much is it?",
      "After the first message, negotiate on behalf of the user.",
      "Talk like a normal helpful person, not like a robot or formal assistant.",
      "Keep every turn very short, polite, direct, and natural.",
      "Use short questions: Can you reduce a little? Is that the final price? What is included? Pickup included? Any extra fee?",
      "Use direct counteroffers like: Can you do 1500?",
      "If the deal sounds ready, say: Okay, let me ask my friend first.",
      "Be context-aware. For taxi or rental car, ask about toll fee, waiting time, pickup/drop-off, luggage, route, and extra charge; do not ask about fuel unless relevant.",
      "For boat, ask about life jacket, round trip, island fee, pickup point, safety, and duration.",
      "For hotel, ask about tax, breakfast, deposit, and late checkout.",
      "For shopping, ask about discount, warranty, original/fake, and delivery.",
      "Do not reveal the user's private budget or private goal.",
      "Never confirm or finalize a deal until user approval."
    ].join(" ");
  }

  function approvalInstructions() {
    return [
      "The user approved this deal.",
      `Confirm the final agreement politely in ${providerLanguage} with the provider.`,
      `Speak only ${providerLanguage} for the provider-facing confirmation.`,
      `Then summarize the final agreement for Trip Notes in ${targetLanguage}.`
    ].join(" ");
  }

  async function translateText(text, language) {
    const cleanText = String(text || "").trim();
    if (!cleanText) return "";

    const { response, data } = await fetchJsonWithRetry(backendUrl("/api/translate"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        text: cleanText,
        targetLanguage: language || "English"
      })
    }, 1);

    if (!response.ok) {
      throw new Error(data.error || "Translation failed.");
    }

    return data.translatedText || "";
  }

  function stopTracks() {
    if (micStream) {
      micStream.getTracks().forEach((track) => track.stop());
      micStream = null;
    }
  }

  window.stopFlutterRealtimeNegotiator = function () {
    manualStop = true;
    clearTimeout(reconnectTimer);
    reconnectTimer = null;

    if (dataChannel) {
      dataChannel.close();
      dataChannel = null;
    }

    if (peerConnection) {
      peerConnection.close();
      peerConnection = null;
    }

    stopTracks();

    if (audioEl) {
      audioEl.srcObject = null;
    }

    emit("status", { message: "Stopped" });
  };

  window.setFlutterRealtimeMuted = function (muted) {
    if (!micStream) {
      emit("status", { message: muted ? "Muted" : "Waiting" });
      return;
    }

    micStream.getAudioTracks().forEach((track) => {
      track.enabled = !muted;
    });

    emit("status", { message: muted ? "Muted" : "Listening" });
  };

  window.approveFlutterRealtimeDeal = function () {
    if (!dataChannel || dataChannel.readyState !== "open") {
      emit("error", { message: "Start realtime voice before approving a deal." });
      return;
    }

    dataChannel.send(JSON.stringify({
      type: "response.create",
      response: {
        modalities: ["audio", "text"],
        instructions: approvalInstructions()
      }
    }));

    emit("approved", { message: `Approved. AI is confirming in ${providerLanguage}.` });
  };

  window.startFlutterRealtimeNegotiator = async function (goal, onEvent, options = {}) {
    emitToFlutter = onEvent;
    activeGoal = goal;
    activeOnEvent = onEvent;
    manualStop = false;
    if (!options.isReconnect) reconnectAttempts = 0;
    aiTurnTranscript = "";
    targetLanguage = parseTargetLanguage(goal);
    providerLanguage = parseProviderLanguage(goal);

    try {
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        throw new Error("Microphone is not available in this browser.");
      }

      window.stopFlutterRealtimeNegotiator();
      manualStop = false;
      emitToFlutter = onEvent;
      emit("status", { message: "Requesting microphone permission..." });

      emit("backend_status", {
        connected: false,
        microphonePermission: false,
        realtimeReady: false,
        backendBaseUrl: backendBaseUrl(),
        customDomainReady: customDomainBackendBaseUrl
      });

      const { response: tokenResponse, data: tokenData } = await fetchJsonWithRetry(backendUrl("/api/realtime-token"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ mode: "negotiator", goal })
      }, 2);

      if (!tokenResponse.ok) {
        throw new Error(tokenData.error || "Could not create realtime session.");
      }

      emit("backend_status", {
        connected: true,
        microphonePermission: false,
        realtimeReady: true,
        backendBaseUrl: backendBaseUrl(),
        customDomainReady: customDomainBackendBaseUrl
      });

      const ephemeralKey = tokenData.value || tokenData.client_secret?.value;
      if (!ephemeralKey) {
        throw new Error("Realtime token was missing.");
      }

      peerConnection = new RTCPeerConnection();
      dataChannel = peerConnection.createDataChannel("oai-events");
      audioEl = document.getElementById("realtime-audio-output") || document.createElement("audio");
      audioEl.id = "realtime-audio-output";
      audioEl.autoplay = true;
      audioEl.playsInline = true;
      audioEl.style.display = "none";
      document.body.appendChild(audioEl);

      peerConnection.addEventListener("connectionstatechange", () => {
        const state = peerConnection ? peerConnection.connectionState : "closed";
        if (state === "connected") emit("status", { message: "Listening" });
        if (["failed", "disconnected"].includes(state)) scheduleReconnect();
        if (state === "closed" && !manualStop) emit("status", { message: "Disconnected" });
      });

      peerConnection.addEventListener("track", (event) => {
        audioEl.srcObject = event.streams[0];
      });

      dataChannel.addEventListener("open", () => {
        emit("status", { message: "AI" });
        dataChannel.send(JSON.stringify({
          type: "response.create",
          response: {
            modalities: ["audio", "text"],
            instructions: negotiationInstructions(goal)
          }
        }));
      });

      dataChannel.addEventListener("message", (event) => {
        const data = JSON.parse(event.data);
        const transcriptEvents = [
          "response.audio_transcript.delta",
          "response.output_audio_transcript.delta",
          "response.output_text.delta"
        ];

        if (transcriptEvents.includes(data.type) && data.delta) {
          aiTurnTranscript += data.delta;
          emit("ai_delta", { text: data.delta, transcript: aiTurnTranscript });
        }

        if (data.type === "input_audio_buffer.speech_started") {
          emit("provider_speaking", { message: "Provider speaking..." });
        }

        if (data.type === "input_audio_buffer.speech_stopped") {
          emit("status", { message: "AI thinking..." });
        }

        if (data.type === "conversation.item.input_audio_transcription.completed" && data.transcript) {
          const providerText = data.transcript;
          emit("provider_transcript", {
            text: providerText,
            translation: `Translating to ${targetLanguage}...`
          });
          emit("status", { message: "AI thinking..." });
          translateText(providerText, targetLanguage)
            .then((translation) => emit("provider_translation", { text: providerText, translation }))
            .catch((error) => emit("provider_translation", {
              text: providerText,
              translation: error.message || "Translation unavailable."
            }));
        }

        if (data.type === "response.done") {
          const aiText = aiTurnTranscript.trim();
          if (aiText) {
            translateText(aiText, targetLanguage)
              .then((translation) => emit("ai_translation", { text: aiText, translation }))
              .catch((error) => emit("ai_translation", {
                text: aiText,
                translation: error.message || "Translation unavailable."
              }));
          }
          emit("ai_turn_done", { text: aiText });
          aiTurnTranscript = "";
          emit("status", { message: "Listening" });
        }

        if (data.type === "error") {
          emit("error", { message: data.error?.message || "Realtime error." });
        }
      });

      micStream = await requestMicrophoneStream();
      emit("backend_status", {
        connected: true,
        microphonePermission: true,
        realtimeReady: true,
        backendBaseUrl: backendBaseUrl(),
        customDomainReady: customDomainBackendBaseUrl
      });
      micStream.getTracks().forEach((track) => peerConnection.addTrack(track, micStream));

      const offer = await peerConnection.createOffer();
      await peerConnection.setLocalDescription(offer);

      const sdpResponse = await fetchWithTimeout("https://api.openai.com/v1/realtime/calls", {
        method: "POST",
        body: offer.sdp,
        headers: {
          "Authorization": `Bearer ${ephemeralKey}`,
          "Content-Type": "application/sdp"
        }
      });

      if (!sdpResponse.ok) {
        throw new Error(await sdpResponse.text());
      }

      await peerConnection.setRemoteDescription({
        type: "answer",
        sdp: await sdpResponse.text()
      });
    } catch (error) {
      window.stopFlutterRealtimeNegotiator();
      emit("error", { message: error.message || "Could not start realtime voice." });
    }
  };

  window.stopFlutterGoalSpeech = function () {
    goalSpeechActive = false;
    if (goalRecognition) {
      goalRecognition.onend = null;
      goalRecognition.stop();
      goalRecognition = null;
    }
  };

  window.startFlutterGoalSpeech = function (onEvent) {
    const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
    if (!SpeechRecognition) {
      onEvent(JSON.stringify({
        type: "goal_speech_error",
        message: "Speech input is not available in this browser."
      }));
      return;
    }

    window.stopFlutterGoalSpeech();
    goalSpeechActive = true;

    const recognition = new SpeechRecognition();
    goalRecognition = recognition;
    recognition.lang = "en-US";
    recognition.continuous = true;
    recognition.interimResults = true;
    recognition.maxAlternatives = 1;

    recognition.onstart = () => {
      onEvent(JSON.stringify({ type: "goal_speech_status", message: "Recording your goal..." }));
    };

    recognition.onerror = (event) => {
      onEvent(JSON.stringify({
        type: "goal_speech_error",
        message: event.error || "Could not hear the goal."
      }));
    };

    recognition.onresult = (event) => {
      let transcript = "";
      let finalText = "";
      for (let index = event.resultIndex; index < event.results.length; index += 1) {
        const part = event.results[index][0].transcript || "";
        transcript += part;
        if (event.results[index].isFinal) finalText += part;
      }
      const textToParse = (finalText || transcript).trim();
      if (!textToParse) return;
      const lower = textToParse.toLowerCase();
      const peopleMatch = lower.match(/(\d+)\s*(people|persons|person|pax|passengers?)/);
      const priceMatch = textToParse.match(/(\d[\d,]*)\s*(thb|baht|บาท|usd|dollars?)/i);
      const durationMatch = lower.match(/(\d+)\s*(hour|hours|hr|hrs|day|days)/);
      const activity = textToParse;
      let destination = "";

      const toMatch = textToParse.match(/\b(?:to|for|near)\s+([^,.]+)/i);
      if (toMatch) destination = toMatch[1].trim();

      onEvent(JSON.stringify({
        type: "goal_speech_result",
        transcript: textToParse,
        destination,
        activity,
        people: peopleMatch ? peopleMatch[1] : "",
        budget: priceMatch ? `${priceMatch[1]} ${priceMatch[2].toUpperCase()}` : "",
        notes: durationMatch ? `Duration mentioned: ${durationMatch[0]}. Ask short, direct questions.` : "Ask short, direct questions."
      }));
    };

    recognition.onend = () => {
      if (goalSpeechActive) {
        setTimeout(() => {
          try {
            recognition.start();
          } catch {
            onEvent(JSON.stringify({ type: "goal_speech_status", message: "Processing voice goal..." }));
          }
        }, 250);
      } else {
        onEvent(JSON.stringify({ type: "goal_speech_status", message: "Processing voice goal..." }));
      }
    };

    recognition.start();
  };

  window.startTravelBuddyGoogleLogin = function () {
    window.open("https://accounts.google.com/", "_blank", "noopener,noreferrer");
  };
})();
