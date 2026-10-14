const express = require('express');
const router = express.Router();
const adminController = require('../controllers/adminController');

// 1. Dashboard สถิติ
router.get('/dashboard', adminController.getDashboardStats);

// 2. จัดการเส้นทางมาตรฐาน
router.get('/routes', adminController.getStandardRoutes);
router.post('/routes', adminController.createStandardRoute);
router.delete('/routes/:id', adminController.deleteStandardRoute);

// 3. จัดการข้อมูลแจ้งเหตุ
router.delete('/reports/:id', adminController.deleteReport);

// 4. ตรวจสอบ AI Moderation
router.get('/ai-moderation', adminController.getAiModerationLogs);

module.exports = router;
