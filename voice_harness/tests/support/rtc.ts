/**
 * Two real WebRTC peers for the voice tests.
 *
 * werift is a full WebRTC implementation (ICE, DTLS, SRTP, RTP) running in Node.
 * It is not the Android stack, so these tests prove the *media/signalling design*
 * — host-candidate connectivity, DTLS-SRTP, RTP flow, teardown — not the Flutter
 * binding. Every assertion here comes from a live peer connection.
 */
import {
  MediaStreamTrack,
  RTCPeerConnection,
  RTCRtpCodecParameters,
  type RTCIceCandidate,
  type RTCSessionDescriptionInit,
} from 'werift';

export const OPUS = new RTCRtpCodecParameters({
  mimeType: 'audio/opus',
  clockRate: 48000,
  channels: 2,
  payloadType: 111,
});

export interface PeerOptions {
  /** STUN/TURN list. Empty means "LAN only, host candidates". */
  iceServers?: { urls: string | string[] }[];
  /** werift otherwise injects stun.l.google.com when iceServers is empty. */
  allowDefaultStun?: boolean;
}

export function createAudioPeer(options: PeerOptions = {}): RTCPeerConnection {
  return new RTCPeerConnection({
    codecs: { audio: [OPUS] },
    iceServers: options.iceServers ?? [],
    // Local mode must never depend on an external STUN server, so the harness
    // disables werift's default Google STUN exactly as the app omits it.
    iceUseDefaultStunServer: options.allowDefaultStun ?? false,
    iceUseIpv6: false,
  });
}

export interface Negotiation {
  offerSdp: string;
  answerSdp: string;
  offerCandidates: string[];
  answerCandidates: string[];
}

export interface PeerPair {
  a: RTCPeerConnection;
  b: RTCPeerConnection;
  localTracks: MediaStreamTrack[];
  remoteTracks: MediaStreamTrack[];
  /** Delivers candidates buffered before the remote description existed. */
  pump(): Promise<void>;
  close(): Promise<void>;
}

/** Adds a sendrecv audio transceiver and records the local tracks. */
export function attachAudio(pc: RTCPeerConnection, pair?: PeerPair): MediaStreamTrack {
  const track = new MediaStreamTrack({ kind: 'audio' });
  pc.addTransceiver(track, { direction: 'sendrecv' });
  pair?.localTracks.push(track);
  return track;
}

export function collectCandidates(
  pc: RTCPeerConnection,
  settleMs = 500,
  timeoutMs = 5000,
): { list: string[]; done: Promise<void> } {
  const list: string[] = [];
  let settle: ReturnType<typeof setTimeout> | null = null;
  let resolveDone: () => void = () => {};
  const done = new Promise<void>((resolve) => {
    resolveDone = resolve;
  });

  // werift keeps `iceGatheringState` at "gathering" when there is no STUN
  // server to finish with, so "quiet for a moment" is the correct completion
  // signal here. This is a harness concern, not a WebRTC bug.
  const finish = () => {
    if (settle) clearTimeout(settle);
    resolveDone();
  };
  const restart = () => {
    if (settle) clearTimeout(settle);
    settle = setTimeout(finish, settleMs);
  };

  pc.onIceCandidate.subscribe((candidate) => {
    if (!candidate.candidate) return;
    list.push(candidate.candidate);
    restart();
  });

  const cap = setTimeout(finish, timeoutMs);
  restart();
  return {
    list,
    done: done.finally(() => clearTimeout(cap)),
  };
}

export async function offerFrom(a: RTCPeerConnection): Promise<RTCSessionDescriptionInit> {
  const offer = await a.createOffer();
  await a.setLocalDescription(offer);
  return offer;
}

export async function answerFrom(b: RTCPeerConnection, offer: RTCSessionDescriptionInit): Promise<RTCSessionDescriptionInit> {
  await b.setRemoteDescription(offer);
  const answer = await b.createAnswer();
  await b.setLocalDescription(answer);
  return answer;
}

export function waitForState(
  pc: RTCPeerConnection,
  wanted: string,
  timeoutMs = 10_000,
): Promise<void> {
  if (pc.connectionState === wanted) return Promise.resolve();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(
      () => reject(new Error(`peer never reached ${wanted}; last state ${pc.connectionState}`)),
      timeoutMs,
    );
    pc.connectionStateChange.subscribe((state) => {
      if (state === wanted) {
        clearTimeout(timer);
        resolve();
      }
    });
  });
}

export function selectedPair(pc: RTCPeerConnection) {
  const transport = pc.dtlsTransports[0];
  return transport?.iceTransport.getSelectedCandidatePair() ?? null;
}

export function candidateType(candidate: string): string {
  const match = / typ (\w+)/.exec(candidate);
  return match?.[1] ?? 'unknown';
}

/** Sends `count` RTP packets carrying an Opus payload type. */
export async function sendAudio(pc: RTCPeerConnection, count = 5, seed = 1): Promise<void> {
  const transceiver = pc.getTransceivers().find((t) => t.kind === 'audio');
  if (!transceiver) throw new Error('no audio transceiver');
  for (let index = 0; index < count; index += 1) {
    const header = Buffer.alloc(12);
    header[0] = 0x80;
    header[1] = OPUS.payloadType;
    header.writeUInt16BE((seed + index) & 0xffff, 2);
    header.writeUInt32BE(960 * (seed + index), 4);
    header.writeUInt32BE(0x22222222 + seed, 8);
    await transceiver.sender.sendRtp(Buffer.concat([header, Buffer.alloc(40, 0xa0 + seed)]));
    await new Promise((resolve) => setTimeout(resolve, 30));
  }
}

/**
 * Collects inbound RTP. Call `attach()` once the connection is established, so
 * the subscription lands on the receiver track that negotiation produced.
 */
export function receiveAudio(
  pc: RTCPeerConnection,
  label: string,
  timeoutMs = 10_000,
): { packets: { seq: number; bytes: number }[]; attach(): Promise<void> } {
  const packets: { seq: number; bytes: number }[] = [];
  const bound = new WeakSet<object>();

  const bindTrack = (maybeTrack: unknown) => {
    const track = (maybeTrack as { track?: unknown })?.track ?? maybeTrack;
    if (!track || typeof track !== 'object' || bound.has(track)) return;
    const receiver = track as { onReceiveRtp?: { subscribe?: unknown } };
    if (typeof receiver.onReceiveRtp?.subscribe !== 'function') return;
    bound.add(track);
    receiver.onReceiveRtp.subscribe(
      (rtp: { header: { sequenceNumber: number }; payload: { length: number } }) => {
        packets.push({ seq: rtp.header.sequenceNumber, bytes: rtp.payload.length });
      },
    );
  };

  pc.onTrack.subscribe((event) => bindTrack(event));

  return {
    packets,
    attach() {
      for (const transceiver of pc.getTransceivers()) {
        if (transceiver.direction === 'recvonly' || transceiver.direction === 'sendrecv') {
          bindTrack(transceiver.receiver?.track);
        }
      }
      return new Promise<void>((resolve, reject) => {
        const started = Date.now();
        const timer = setInterval(() => {
          if (packets.length >= 3) {
            clearInterval(timer);
            resolve();
          } else if (Date.now() - started > timeoutMs) {
            clearInterval(timer);
            reject(new Error(`${label} received ${packets.length} RTP packets, expected 3`));
          }
        }, 50);
        if (typeof timer.unref === 'function') timer.unref();
      });
    },
  };
}

export async function makePair(options: PeerOptions = {}): Promise<PeerPair> {
  const a = createAudioPeer(options);
  const b = createAudioPeer(options);
  const pendingForB: RTCIceCandidate[] = [];
  const pendingForA: RTCIceCandidate[] = [];

  // Trickle ICE between the two peers, buffering until each side has a remote
  // description (the same ordering the app gets from the relay).
  a.onIceCandidate.subscribe((candidate) => {
    if (!candidate.candidate) return;
    if (b.remoteDescription) void b.addIceCandidate(candidate).catch(() => {});
    else pendingForB.push(candidate);
  });
  b.onIceCandidate.subscribe((candidate) => {
    if (!candidate.candidate) return;
    if (a.remoteDescription) void a.addIceCandidate(candidate).catch(() => {});
    else pendingForA.push(candidate);
  });

  const pair: PeerPair = {
    a,
    b,
    localTracks: [],
    remoteTracks: [],
    async pump() {
      for (const candidate of pendingForB.splice(0)) {
        await b.addIceCandidate(candidate).catch(() => {});
      }
      for (const candidate of pendingForA.splice(0)) {
        await a.addIceCandidate(candidate).catch(() => {});
      }
    },
    async close() {
      await a.close().catch(() => {});
      await b.close().catch(() => {});
    },
  };
  attachAudio(a, pair);
  attachAudio(b, pair);
  return pair;
}
