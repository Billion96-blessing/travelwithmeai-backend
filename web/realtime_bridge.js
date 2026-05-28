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
  const defaultBackendBaseUrl = "https://travelwithmeai-server.onrender.com";
  const customDomainBackendBaseUrl = "https://api.travelwithmeai.com";

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
      `Your first message must: greet the provider, say you are helping your friend/customer communicate, briefly say the customer wants ${request}, then ask the price.`,
      "Example meaning: Hello, I am helping my friend/customer communicate. They want this service. May I ask the price?",
      "After the first message, negotiate on behalf of the user.",
      "Talk like a normal friendly person, not like a complicated AI.",
      "Close the deal faster. Keep each turn under one or two short sentences.",
      "Use short, straight questions: How much can you reduce? What is the final price? What is included? Pickup and drop-off included? Any extra fee?",
      "Use direct counteroffers like: Okay, can you do 1500?",
      "Be context-aware. For taxi or rental car, ask about toll fee, waiting time, pickup/drop-off, luggage, route, and extra charge; do not ask about fuel unless relevant.",
      "For boat, ask about life jacket, round trip, island fee, pickup point, safety, and duration.",
      "For hotel, ask about tax, breakfast, deposit, and late checkout.",
      "For shopping, ask about discount, warranty, original/fake, and delivery.",
      "Do not reveal the user's private budget or private goal.",
      "Do not finalize a deal until user approval."
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

    const response = await fetch(backendUrl("/api/translate"), {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        text: cleanText,
        targetLanguage: language || "English"
      })
    });

    const data = await response.json();
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

  window.startFlutterRealtimeNegotiator = async function (goal, onEvent) {
    emitToFlutter = onEvent;
    aiTurnTranscript = "";
    targetLanguage = parseTargetLanguage(goal);
    providerLanguage = parseProviderLanguage(goal);

    try {
      if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) {
        throw new Error("Microphone is not available in this browser.");
      }

      window.stopFlutterRealtimeNegotiator();
      emitToFlutter = onEvent;
      emit("status", { message: "Requesting microphone permission..." });

      emit("backend_status", {
        connected: false,
        microphonePermission: false,
        realtimeReady: false,
        backendBaseUrl: backendBaseUrl(),
        customDomainReady: customDomainBackendBaseUrl
      });

      const tokenResponse = await fetch(backendUrl("/api/realtime-token"), {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ mode: "negotiator", goal })
      });

      const tokenData = await tokenResponse.json();
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
        if (["failed", "disconnected", "closed"].includes(state)) emit("status", { message: "Disconnected" });
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

        if (data.type === "conversation.item.input_audio_transcription.completed" && data.transcript) {
          const providerText = data.transcript;
          emit("provider_transcript", {
            text: providerText,
            translation: `Translating to ${targetLanguage}...`
          });
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

      micStream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true
        }
      });
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

      const sdpResponse = await fetch("https://api.openai.com/v1/realtime/calls", {
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
