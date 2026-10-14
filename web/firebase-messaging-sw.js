// Firebase Cloud Messaging Service Worker for Running Route Finder Web Push
importScripts('https://www.gstatic.com/firebasejs/10.7.0/firebase-app-compat.js');
importScripts('https://www.gstatic.com/firebasejs/10.7.0/firebase-messaging-compat.js');

// Config ค่า Firebase Project (จะถูก initialize เมื่อมี Push เข้ามา)
// ค่าเหล่านี้ตรงกับ DefaultFirebaseOptions.web
firebase.initializeApp({
  apiKey: "AIzaSyADaoTVALQz40pguSEWOhVUBjtnZ2XttTg",
  authDomain: "fir-walkrunbike-f6792.firebaseapp.com",
  projectId: "fir-walkrunbike-f6792",
  storageBucket: "fir-walkrunbike-f6792.firebasestorage.app",
  messagingSenderId: "1033737834173",
  appId: "1:1033737834173:web:c876c9283b31a46abcb1d4",
  measurementId: "G-5ZWBG8TW2B"
});

const messaging = firebase.messaging();

messaging.onBackgroundMessage((payload) => {
  console.log('[firebase-messaging-sw.js] Received background message: ', payload);
  const notificationTitle = payload.notification?.title || 'Running Finder';
  const notificationOptions = {
    body: payload.notification?.body || 'มีการแจ้งเตือนใหม่',
    icon: '/icons/Icon-192.png',
    badge: '/icons/Icon-192.png',
    data: payload.data
  };

  self.registration.showNotification(notificationTitle, notificationOptions);
});
