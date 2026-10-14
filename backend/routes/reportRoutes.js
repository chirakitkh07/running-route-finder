const express = require('express');
const router = express.Router();
const reportController = require('../controllers/reportController');

// GET all active hazard reports
router.get('/', reportController.getAllActiveReports);

// GET verification result for a report (FR18)
router.get('/:id/verify', reportController.verifyReport);

// POST a new hazard report (pin)
router.post('/', reportController.createReport);

// PATCH to vote verify/reject a report
router.patch('/:id/vote', reportController.voteReport);

module.exports = router;
