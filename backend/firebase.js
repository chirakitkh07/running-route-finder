const admin = require('firebase-admin');
const path = require('path');

// Initialize Firebase Admin SDK
try {
  // You need to generate serviceAccountKey.json from Firebase Console:
  // Project Settings -> Service Accounts -> Generate New Private Key
  // and place it in the same directory as this file (backend/serviceAccountKey.json)
  const serviceAccount = require('./serviceAccountKey.json');
  
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount)
  });
  
  console.log('🔥 Firebase Admin initialized successfully.');
} catch (error) {
  console.error('❌ Failed to initialize Firebase Admin. Please ensure serviceAccountKey.json exists.');
  console.error(error.message);
}

const db = admin.firestore();

module.exports = { admin, db };
