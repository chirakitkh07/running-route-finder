/**
 * ตัวส่งแจ้งเตือน Push (FCM) — ฟัง Firestore แบบ real-time แล้วส่งแจ้งเตือนผ่าน firebase-admin
 * ใช้ได้กับแผนฟรี (Spark) ไม่ต้องใช้ Cloud Functions แต่ต้องเปิดสคริปต์นี้ค้างไว้
 *
 *   ต้องมี backend/serviceAccountKey.json (Firebase Console → Project settings → Service accounts)
 *   cd backend
 *   node scripts/fcm_worker.js              # เริ่มฟังและส่งแจ้งเตือน
 *   node scripts/fcm_worker.js --test <uid> # ส่งแจ้งเตือนทดสอบหาผู้ใช้คนเดียว
 *
 * เหตุการณ์ที่แจ้ง
 *   - incidents ใหม่ (status = active)       → topic incidents_th / incidents_en (ทุกคน)
 *   - comment ใหม่ในกิจกรรม                 → เจ้าของกิจกรรม (users/{uid}.fcmTokens)
 *   - มีคนกดถูกใจกิจกรรม                    → เจ้าของกิจกรรม
 */
const { admin, db } = require('../firebase');

const CHANNEL_ID = 'rrf_alerts';
const startedAt = new Date();

const INCIDENT_LABELS = {
  dogs: ['🐶 สุนัขจรจัด/ดุร้าย', '🐶 Stray/aggressive dogs'],
  slippery: ['🌧️ ถนน/ทางลื่น', '🌧️ Slippery road/path'],
  construction: ['🚧 มีการก่อสร้าง/ปิดทาง', '🚧 Construction/road closed'],
  lighting: ['🌙 ไฟส่องสว่างดับ/มืด', '🌙 Broken lights/dark'],
  flooding: ['🌊 น้ำท่วมขัง', '🌊 Flooding'],
  accident: ['🚨 เกิดอุบัติเหตุ', '🚨 Accident'],
};
const incidentLabel = (type) => INCIDENT_LABELS[type] || ['⚠️ เหตุการณ์/สิ่งกีดขวาง', '⚠️ Incident/obstacle'];

const toDate = (v) => (v && typeof v.toDate === 'function' ? v.toDate() : null);
const short = (s, n = 80) => (s && s.length > n ? `${s.slice(0, n - 1)}…` : s || '');

/** data ของ FCM ต้องเป็น string ทั้งหมด */
function stringify(data) {
  const out = {};
  for (const [k, v] of Object.entries(data)) {
    if (v !== undefined && v !== null) out[k] = String(v);
  }
  return out;
}

function buildMessage({ title, body, data }) {
  return {
    notification: { title, body },
    data: stringify(data),
    // tag = notifId → ถ้าแอปแสดงแจ้งเตือนเดียวกันเองแล้ว (PushService.showSystemNotification) จะแทนที่กัน ไม่ซ้ำ
    android: { priority: 'high', notification: { channelId: CHANNEL_ID, tag: data.notifId } },
    apns: { payload: { aps: { sound: 'default' } } },
  };
}

/** ส่งหาทุกเครื่องของผู้ใช้ เลือกภาษาตาม fcmLang และลบ token ที่ใช้ไม่ได้แล้ว */
async function sendToUser(uid, { th, en, data }) {
  const userRef = db.collection('users').doc(uid);
  const snap = await userRef.get();
  const user = snap.data() || {};
  const tokens = Array.isArray(user.fcmTokens) ? user.fcmTokens : [];
  if (tokens.length === 0) {
    console.log(`  · ${uid} ไม่มี token (ยังไม่เคยเปิดแอปเวอร์ชันที่มี FCM)`);
    return;
  }
  const [title, body] = user.fcmLang === 'en' ? en : th;
  const res = await admin.messaging().sendEachForMulticast({
    ...buildMessage({
      title,
      body,
      data: { ...data, titleTh: th[0], bodyTh: th[1], titleEn: en[0], bodyEn: en[1] },
    }),
    tokens,
  });
  const dead = [];
  res.responses.forEach((r, i) => {
    const code = r.error && r.error.code;
    if (code === 'messaging/registration-token-not-registered' || code === 'messaging/invalid-registration-token') {
      dead.push(tokens[i]);
    }
  });
  if (dead.length) {
    await userRef.update({ fcmTokens: admin.firestore.FieldValue.arrayRemove(...dead) });
  }
  console.log(`  → ${uid}: สำเร็จ ${res.successCount}/${tokens.length}${dead.length ? `, ลบ token เสีย ${dead.length}` : ''}`);
}

async function userName(uid) {
  try {
    const d = (await db.collection('users').doc(uid).get()).data() || {};
    return d.displayName || d.name || 'นักวิ่ง';
  } catch (_) {
    return 'นักวิ่ง';
  }
}

// ─── เหตุการณ์ใหม่ → ทุกคน ─────────────────────────────────────────────
function watchIncidents() {
  db.collection('incidents')
    .where('createdAt', '>', admin.firestore.Timestamp.fromDate(startedAt))
    .onSnapshot((snap) => {
      snap.docChanges().forEach(async (change) => {
        if (change.type !== 'added') return;
        const r = change.doc.data();
        if (r.status && r.status !== 'active') return;
        const [labelTh, labelEn] = incidentLabel(r.type);
        const desc = r.description ? ` • ${short(r.description)}` : '';
        const data = stringify({
          type: 'incident',
          notifId: `incident_${change.doc.id}`,
          incidentId: change.doc.id,
          actorUid: r.userId,
          lat: r.latitude,
          lng: r.longitude,
        });
        console.log(`[incident] ${change.doc.id} ${r.type}`);
        try {
          await admin.messaging().send({
            ...buildMessage({ title: `🚨 เหตุการณ์ใหม่: ${labelTh}`, body: `รายงานโดย ${r.userName || 'นักวิ่ง'}${desc}`, data }),
            topic: 'incidents_th',
          });
          await admin.messaging().send({
            ...buildMessage({ title: `🚨 Incident Alert: ${labelEn}`, body: `Reported by ${r.userName || 'Runner'}${desc}`, data }),
            topic: 'incidents_en',
          });
        } catch (e) {
          console.error('[incident] ส่งไม่สำเร็จ', e.message);
        }
      });
    }, (e) => console.error('[incident] stream error', e.message));
}

// ─── comment ใหม่ → เจ้าของกิจกรรม ──────────────────────────────────────
function watchComments() {
  let first = true;
  db.collectionGroup('comments').onSnapshot((snap) => {
    if (first) { first = false; return; } // ข้ามคอมเมนต์เก่าตอนเริ่ม
    snap.docChanges().forEach(async (change) => {
      if (change.type !== 'added') return;
      const activityRef = change.doc.ref.parent.parent;
      // ข้าม users/{uid}/comments (ไม่ใช่คอมเมนต์ของกิจกรรม)
      if (!activityRef || activityRef.parent.id !== 'activities') return;
      const c = change.doc.data();
      const created = toDate(c.createdAt);
      if (created && created < startedAt) return;
      try {
        const activity = (await activityRef.get()).data();
        if (!activity || !activity.uid || activity.uid === c.uid) return;
        const title = activity.title || 'กิจกรรม';
        const text = short(c.text, 100);
        console.log(`[comment] ${c.authorName} → ${activity.uid}`);
        await sendToUser(activity.uid, {
          th: ['💬 ความคิดเห็นใหม่ในกิจกรรม', `${c.authorName}: "${text}"`],
          en: ['💬 New Comment on your activity', `${c.authorName}: "${text}"`],
          data: {
            type: 'comment',
            notifId: `comment_${activityRef.id}_${change.doc.id}`,
            activityId: activityRef.id,
            actorUid: c.uid,
            activityTitle: title,
          },
        });
      } catch (e) {
        console.error('[comment] ส่งไม่สำเร็จ', e.message);
      }
    });
  }, (e) => console.error('[comment] stream error', e.message));
}

// ─── กดถูกใจ → เจ้าของกิจกรรม ───────────────────────────────────────────
function watchLikes() {
  const likedBy = new Map(); // activityId → Set(uid) ล่าสุดที่เห็น
  const notified = new Set(); // `${activityId}_${uid}` กันแจ้งซ้ำ (กดถูกใจ/เลิก/ถูกใจใหม่ หรือสำเนา global+user)
  let first = true;
  db.collectionGroup('activities').onSnapshot((snap) => {
    snap.docChanges().forEach(async (change) => {
      const id = change.doc.id;
      const a = change.doc.data();
      const now = new Set(Array.isArray(a.likedBy) ? a.likedBy : []);
      const before = likedBy.get(id);
      likedBy.set(id, before ? new Set([...before, ...now]) : now);
      if (first || change.type !== 'modified' || !before) return;
      for (const uid of now) {
        if (before.has(uid) || uid === a.uid || notified.has(`${id}_${uid}`)) continue;
        notified.add(`${id}_${uid}`);
        const name = await userName(uid);
        const title = a.title || 'กิจกรรม';
        console.log(`[like] ${name} → ${a.uid}`);
        try {
          await sendToUser(a.uid, {
            th: ['❤️ มีคนถูกใจกิจกรรมของคุณ', `${name} ได้ถูกใจ "${title}"`],
            en: ['❤️ New Like on your activity', `${name} liked "${title}"`],
            data: { type: 'like', notifId: `like_${id}_${uid}`, activityId: id, actorUid: uid },
          });
        } catch (e) {
          console.error('[like] ส่งไม่สำเร็จ', e.message);
        }
      }
    });
    first = false;
  }, (e) => console.error('[like] stream error', e.message));
}

async function sendTest(uid) {
  await sendToUser(uid, {
    th: ['🔔 ทดสอบการแจ้งเตือน', 'ระบบแจ้งเตือน FCM ทำงานปกติ'],
    en: ['🔔 Test notification', 'FCM push notifications are working'],
    data: { type: 'system', notifId: `test_${Date.now()}` },
  });
  process.exit(0);
}

const testIdx = process.argv.indexOf('--test');
if (testIdx >= 0) {
  const uid = process.argv[testIdx + 1];
  if (!uid) {
    console.error('ใช้: node scripts/fcm_worker.js --test <uid>');
    process.exit(1);
  }
  sendTest(uid).catch((e) => { console.error(e); process.exit(1); });
} else {
  console.log(`🔔 FCM worker เริ่มทำงาน ${startedAt.toLocaleString('th-TH')} — กด Ctrl+C เพื่อหยุด`);
  watchIncidents();
  watchComments();
  watchLikes();
}
