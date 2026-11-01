ROLE: PRINCIPAL SOFTWARE ARCHITECT, UI/UX DESIGNER & FULL-STACK ENGINEERING TEAM

Act as a world-class principal software architect, senior Flutter developer, React/Next.js developer, backend engineer, PostgreSQL database architect, AI engineer, security engineer and premium UI/UX designer.

Your task is to design and build a COMPLETE, PRODUCTION-READY GYM & FITNESS ECOSYSTEM.

Do not build a basic gym management application or a simple workout tracker. Build a scalable SaaS platform combining:

1. Gym Management SaaS.
2. Personal Fitness Application.
3. Personal Trainer Management.
4. Diet and Nutrition Management.
5. Fitness Marketplace.
6. AI-Powered Fitness Assistant.
7. Super Admin Platform.

The platform must support small gyms, medium-sized gyms, premium fitness centres, independent personal trainers, nutritionists, physiotherapists and large gym chains.

The application must be designed for India initially, but its architecture must support international expansion.

---

1. PRODUCT ARCHITECTURE

Build four connected applications using one central backend.

A. GYM MANAGEMENT APPLICATION

- Gym owners.
- Gym managers.
- Branch managers.
- Receptionists.
- Accountants.
- Gym staff.

B. FITNESS APPLICATION

- Gym members.
- Independent fitness users.
- Users without gym memberships.

C. TRAINER APPLICATION

- Personal trainers.
- Fitness coaches.
- Senior trainers.
- Nutritionists.
- Physiotherapists.

D. SUPER ADMIN WEB APPLICATION

- Platform administrators.
- Support administrators.
- Finance administrators.
- Moderators.

One user account must be able to have multiple roles and belong to multiple gyms.

A user should be able to use basic fitness tracking without joining a gym.

All modules must communicate through the central backend.

2. TECHNOLOGY STACK

Use the following architecture unless an existing repository has a valid, documented implementation that should be preserved.

MOBILE:

- Flutter.
- Dart.
- Material 3.
- Riverpod or another consistent scalable state-management solution.
- GoRouter.
- Dio.
- Secure local storage.
- Local caching and offline synchronization.

WEB:

- Next.js.
- React.
- TypeScript.
- Tailwind CSS.
- A reusable component system.
- Responsive desktop, tablet and mobile layouts.

BACKEND:

- NestJS.
- TypeScript.
- REST API.
- WebSockets for real-time features.
- Modular monolith architecture.
- Background job processing.

DATABASE:

- PostgreSQL.
- Prisma ORM or Drizzle ORM.
- UUID primary keys.
- Database migrations.
- Foreign keys.
- Indexes.
- Row Level Security.
- Tenant-level data isolation.

INFRASTRUCTURE:

- Redis for caching and queues.
- S3-compatible object storage.
- Firebase Authentication or managed OIDC.
- Firebase Cloud Messaging.
- Brevo email integration.
- Official WhatsApp Business API integration.
- Gemini API for AI features.
- Razorpay/Cashfree as optional payment providers.
- Sentry for error monitoring.

Use environment variables for every secret and API key.

Never hardcode API keys, passwords or payment credentials.

3. MULTI-TENANT SAAS ARCHITECTURE

Implement a secure multi-tenant system.

Each gym is a separate tenant.

Each gym can have multiple branches.

Every tenant-owned database record must have the appropriate tenant_id.

Implement:

- Tenant isolation.
- Branch-level permissions.
- Role-based access control.
- Permission-based API authorization.
- PostgreSQL RLS.
- Tenant-aware queries.
- Subscription-based feature access.
- Usage limits.
- Tenant suspension.
- Trial subscriptions.
- Plan upgrades and downgrades.

A gym must never be able to access another gym's members, payments, trainers, reports or personal information.

Never trust tenant_id or role information supplied by an untrusted client. Derive and validate access from authenticated server-side identity and membership records.

4. COMPLETE USER ROLES

Create these roles:

1. Super Admin.
2. Support Admin.
3. Finance Admin.
4. Gym Owner.
5. Gym Manager.
6. Branch Manager.
7. Receptionist.
8. Accountant.
9. Senior Trainer.
10. Personal Trainer.
11. Nutritionist.
12. Physiotherapist.
13. Gym Member.
14. Independent Fitness User.
15. Marketplace Customer.

Implement granular permissions.

Examples:

- Trainer can access only assigned clients.
- Accountant can access financial modules without unnecessary access to health records.
- Branch manager can access only assigned branches.
- Member can access only their personal data.
- Owner can manage their own gym.
- Super Admin has platform-level permissions with audited privileged access.

Allow users to have multiple roles.

5. COMPLETE GYM MANAGEMENT MODULE

Implement the following:

GYM ONBOARDING:

- Gym registration.
- Gym profile.
- Logo upload.
- Gym photos.
- Gym description.
- Contact information.
- Location and address.
- Opening hours.
- Facilities.
- Multiple branches.
- Staff management.
- Gym verification.
- Gym subscription management.
- Gym branding.

MEMBER MANAGEMENT:

- Member registration.
- Profile management.
- Member photographs.
- Contact details.
- Emergency contact.
- Consent-based health disclosures.
- Member ID.
- QR ID card.
- Membership assignment.
- Membership history.
- Member search.
- Advanced filtering.
- Bulk Excel import.
- Member transfer.
- Member status management.
- Activity timeline.

MEMBERSHIP MANAGEMENT:

- Daily plans.
- Weekly plans.
- Monthly plans.
- Quarterly plans.
- Half-yearly plans.
- Annual plans.
- Student plans.
- Couple plans.
- Family plans.
- Corporate plans.
- Personal training packages.
- Group-class packages.
- Trial memberships.
- Custom pricing.
- Joining fees.
- Discount coupons.
- Renewal management.
- Freeze membership.
- Membership transfer.
- Upgrade and downgrade.
- Grace period.
- Instalments.
- Expiry alerts.
- Membership reports.

ATTENDANCE:

- QR code check-in.
- QR code check-out.
- Manual attendance.
- Receptionist check-in.
- NFC integration where supported.
- Biometric integration where supported.
- Offline attendance queue.
- Duplicate attendance prevention.
- Membership validation.
- Branch-wise attendance.
- Daily reports.
- Peak-hour analytics.
- Occupancy indicator.

6. WORKOUT MANAGEMENT ENGINE

Build a complete workout management system.

EXERCISE LIBRARY:

- Exercise name.
- Description.
- Muscle group.
- Difficulty level.
- Required equipment.
- Demonstration videos.
- Instructions.
- Common mistakes.
- Safety precautions.
- Alternative exercises.

MUSCLE GROUPS:

- Chest.
- Back.
- Shoulders.
- Biceps.
- Triceps.
- Legs.
- Glutes.
- Abs.
- Cardio.
- Full body.

WORKOUT PLANNER:

- Create workout plans.
- Weekly calendar.
- Push/Pull/Legs.
- Upper/lower split.
- Full-body programs.
- Weight-loss programs.
- Muscle-building programs.
- Strength programs.
- Home workout plans.
- Beginner programs.
- Intermediate programs.
- Advanced programs.
- Assign plans to members.

WORKOUT TRACKER:

- Sets.
- Repetitions.
- Weight.
- Rest timer.
- Workout duration.
- Workout completion.
- Personal records.
- Exercise history.
- Trainer comments.
- Workout consistency.
- Progress charts.

7. DIET AND NUTRITION MODULE

Implement:

- Personalized diet plans.
- Vegetarian diet plans.
- Non-vegetarian diet plans.
- Indian regional food database.
- Food items.
- Meal schedules.
- Breakfast.
- Lunch.
- Dinner.
- Snacks.
- Calorie calculator.
- Protein tracking.
- Carbohydrate tracking.
- Fat tracking.
- Water intake.
- Meal reminders.
- Food substitutions.
- Grocery lists.
- Weekly meal calendar.
- Nutritionist assignments.
- Diet plan PDF export.

Allow users to enter dietary preferences, allergies and food restrictions.

AI-generated diet plans must be treated as suggestions and reviewed by qualified professionals where appropriate.

8. PERSONAL TRAINER MANAGEMENT

Implement:

- Trainer profiles.
- Qualifications.
- Certificates.
- Experience.
- Specializations.
- Availability.
- Client assignments.
- Training schedules.
- Personal training packages.
- Session booking.
- Session completion.
- Trainer attendance.
- Trainer commission.
- Trainer salary.
- Client feedback.
- Trainer ratings.
- Trainer calendar.
- Trainer-client communication.
- Client progress reports.

9. BODY TRANSFORMATION MODULE

Track:

- Weight.
- Height.
- BMI.
- Body fat percentage.
- Chest.
- Waist.
- Hip.
- Arms.
- Thighs.
- Shoulder measurements.
- Progress photographs.
- Monthly comparisons.
- Weight history.
- Goal completion.
- Personal records.
- Workout consistency.

Build interactive graphs.

Add private/public photo visibility controls.

Never expose private body photographs or measurements without permission.

10. AI FITNESS FEATURES

Integrate Gemini API through secure backend endpoints.

Implement:

AI WORKOUT PLANNER:
Generate workout plan drafts based on:

- Fitness goals.
- Experience.
- Available equipment.
- Weekly availability.
- Workout duration.
- Declared limitations.

AI DIET PLANNER:
Generate meal plan drafts based on:

- Calorie targets.
- Dietary preferences.
- Food restrictions.
- Allergies.
- Food budget.
- Regional Indian food preferences.

AI FITNESS ASSISTANT:

- Answer general fitness questions.
- Explain exercises.
- Explain workout routines.
- Suggest safe modifications.
- Explain nutrition concepts.

AI PROGRESS ANALYSIS:

- Analyse recorded progress.
- Identify trends.
- Generate weekly reports.
- Suggest consistency improvements.

AI EXERCISE FORM ANALYSIS:

- Start with a limited number of validated exercises.
- Use camera-based pose estimation.
- Analyse supported movement patterns.
- Show understandable feedback.
- Clearly communicate uncertainty.
- Do not diagnose injuries.

Implement usage limits, AI request logs, cost monitoring and fallback responses.

AI must not prescribe treatment, diagnose medical conditions or promise guaranteed transformations.

11. FITNESS CLASSES AND BOOKING

Implement:

- Yoga.
- Zumba.
- HIIT.
- Pilates.
- CrossFit.
- Boxing.
- Dance fitness.
- Spinning.
- Group strength training.
- Online fitness classes.

Features:

- Class schedules.
- Class capacity.
- Booking.
- Cancellation.
- Waiting list.
- Trainer assignment.
- Attendance.
- Booking reminders.
- Class reviews.
- Live-class links.

Prevent double booking and over-capacity reservations using database transactions.

12. FITNESS MARKETPLACE

Create a discovery marketplace.

GYM DISCOVERY:

- Find gyms nearby.
- Search by city.
- Search by locality.
- Search by PIN code.
- Filters.
- Gym facilities.
- Photos.
- Ratings.
- Reviews.
- Membership comparison.
- Trial booking.
- Favourite gyms.

TRAINER DISCOVERY:

- Find personal trainers.
- Trainer profiles.
- Qualifications.
- Experience.
- Specializations.
- Pricing.
- Availability.
- Booking.
- Ratings.

NUTRITIONIST DISCOVERY:

- Nutritionist profiles.
- Qualifications.
- Consultation services.
- Availability.
- Booking.
- Reviews.

Add verified listing status, moderation, reporting and provider controls.

13. PAYMENTS AND ACCOUNTING

Build separate payment systems for gym collections and platform subscriptions.

GYM FINANCE:

- Membership invoices.
- Online payments.
- UPI payments.
- Payment receipts.
- Pending fees.
- Refunds.
- Discounts.
- Trainer commissions.
- Expenses.
- Salaries.
- Daily collection.
- Monthly revenue.
- Profit and loss reports.
- Transaction exports.

SAAS BILLING:

- Starter plan.
- Growth plan.
- Professional plan.
- Enterprise plan.
- Monthly subscription.
- Annual subscription.
- Trial period.
- Plan upgrades.
- Plan downgrades.
- Subscription invoices.
- Subscription payments.
- Renewal.
- Failed payment handling.
- Subscription expiry.

GYM MEMBER COLLECTIONS MUST BE SETTLED DIRECTLY TO THE GYM'S OWN MERCHANT ACCOUNT OR APPROVED PAYMENT ARRANGEMENT.

Do not combine gym member collections with platform revenue.

Use signed payment webhooks, idempotency, server-side verification and immutable transaction references.

14. NOTIFICATIONS AND COMMUNICATION

Integrate:

- Firebase Cloud Messaging.
- Email.
- Official WhatsApp Business API.

Notification events:

- Membership expiry.
- Membership renewal.
- Payment due.
- Payment successful.
- Workout reminder.
- Diet reminder.
- Trainer session reminder.
- Class booking.
- Gym announcements.
- Birthday messages.
- Inactive member alerts.
- Emergency announcements.

Create:

- Notification preferences.
- Scheduled notification jobs.
- Retry handling.
- Duplicate prevention.
- Delivery logs.
- Consent management.
- Template management.

15. INVENTORY AND EQUIPMENT MANAGEMENT

Implement:

- Equipment registration.
- Equipment purchase.
- Purchase date.
- Warranty.
- Maintenance schedule.
- Repair history.
- Equipment availability.
- Consumables.
- Supplements.
- Stock management.
- Suppliers.
- Purchase orders.
- Low-stock notifications.
- Equipment downtime.

16. SUPER ADMIN PLATFORM

Build a comprehensive Super Admin dashboard.

DASHBOARD:

- Total gyms.
- Active gyms.
- Trial gyms.
- Suspended gyms.
- Total users.
- Active members.
- New registrations.
- Monthly recurring revenue.
- Annual recurring revenue.
- Payment statistics.
- Marketplace performance.
- Subscription conversion.
- Churn.
- Platform usage.

MANAGEMENT:

- Gym management.
- User management.
- Subscription plans.
- Feature flags.
- Coupons.
- Payment monitoring.
- Gym verification.
- Marketplace moderation.
- Support tickets.
- Announcements.
- Audit logs.
- Platform configuration.

Provide appropriate role restrictions and audit every privileged operation.

17. COMPLETE DATABASE SCHEMA

Create normalized PostgreSQL schemas and migrations for:

PLATFORM:

- users
- user_profiles
- roles
- permissions
- role_permissions
- user_roles
- user_devices
- user_consents
- user_sessions
- audit_logs

GYM:

- tenants
- gym_profiles
- gym_branches
- gym_facilities
- gym_photos
- gym_hours
- gym_staff
- gym_members
- member_documents
- member_emergency_contacts
- gym_enquiries
- gym_settings

MEMBERSHIP:

- membership_plans
- membership_features
- member_subscriptions
- subscription_freezes
- subscription_changes
- membership_visits
- attendance_devices
- attendance_events
- membership_coupons

WORKOUT:

- exercise_categories
- exercises
- exercise_media
- workout_templates
- workout_template_exercises
- member_workout_plans
- workout_days
- workout_exercises
- workout_sessions
- workout_sets
- fitness_goals
- personal_records

NUTRITION:

- food_items
- meal_plans
- meal_plan_assignments
- meal_plan_items
- food_logs
- water_logs
- nutrition_profiles
- nutrition_consultations

TRAINERS:

- trainer_profiles
- trainer_specializations
- trainer_clients
- trainer_availability
- training_packages
- training_bookings
- training_sessions
- trainer_reviews

PROGRESS:

- body_measurements
- body_compositions
- progress_photos
- health_disclosures
- activity_records

MARKETPLACE:

- marketplace_listings
- listing_locations
- listing_services
- listing_photos
- listing_reviews
- listing_favourites
- marketplace_enquiries
- marketplace_bookings

FINANCE:

- invoices
- invoice_items
- payments
- payment_transactions
- refunds
- expenses
- staff_payroll
- trainer_commissions
- financial_ledger_entries
- gym_payout_accounts

SAAS:

- saas_plans
- saas_plan_features
- tenant_subscriptions
- saas_invoices
- saas_payments
- usage_metrics
- feature_flags
- support_tickets
- platform_announcements
- notification_templates
- notification_jobs

Create proper:

- Foreign keys.
- Unique constraints.
- Composite indexes.
- Check constraints.
- Tenant isolation policies.
- Soft deletion where appropriate.
- Migration files.
- Seed data.
- Test fixtures.

Do not create a single unstructured JSON table for all application data.

18. COMPLETE API ARCHITECTURE

Build versioned REST APIs.

Use:

/api/v1/auth
/api/v1/gyms
/api/v1/branches
/api/v1/members
/api/v1/memberships
/api/v1/attendance
/api/v1/workouts
/api/v1/exercises
/api/v1/nutrition
/api/v1/trainers
/api/v1/bookings
/api/v1/payments
/api/v1/invoices
/api/v1/reports
/api/v1/marketplace
/api/v1/notifications
/api/v1/saas
/api/v1/admin

Requirements:

- DTO validation.
- Standardized response format.
- Error handling.
- Pagination.
- Sorting.
- Filtering.
- Authentication middleware.
- Authorization guards.
- API documentation through Swagger.
- Rate limiting.
- Request logging.
- Idempotency for critical operations.

19. COMPLETE UI/UX DESIGN REQUIREMENTS

Design a PREMIUM, MODERN FITNESS TECHNOLOGY EXPERIENCE.

Do not use a generic admin template.

VISUAL STYLE:

- Premium fitness-tech aesthetics.
- Dark charcoal backgrounds.
- Clean white light theme.
- Electric lime or vibrant green primary accent.
- Orange secondary accent.
- Premium typography.
- Rounded cards.
- Clear spacing.
- Beautiful statistics.
- Interactive charts.
- High-quality fitness images.
- Smooth transitions.
- Animated progress rings.
- Micro-interactions.
- Skeleton loading.
- Beautiful empty states.

RESPONSIVE DESIGN:

- Android phones.
- iPhones.
- Android tablets.
- iPads.
- Desktop.
- Large desktop monitors.

LIGHT AND DARK MODE:

- Fully supported.
- Animated theme switching.
- Persist user preference.
- Consistent colours across every screen.

ANIMATIONS:

- Smooth page transitions.
- Animated bottom navigation.
- Animated cards.
- Button interactions.
- Loading animations.
- Progress animations.
- Charts.
- Dialogs and bottom sheets.

Do not overuse animations or compromise performance.

20. COMPLETE SCREEN LIST

AUTHENTICATION:

- Splash.
- Onboarding.
- Welcome.
- Login.
- Registration.
- Email verification.
- Phone verification.
- Password recovery.
- Role selection.
- Location selection.

GYM OWNER:

- Dashboard.
- Members.
- Member profile.
- Add member.
- Membership plans.
- Subscription details.
- Attendance.
- QR scanner.
- Trainers.
- Staff.
- Classes.
- Payments.
- Invoices.
- Expenses.
- Reports.
- Inventory.
- Branches.
- Settings.

TRAINER:

- Dashboard.
- My clients.
- Client profile.
- Workout planner.
- Exercise library.
- Create workout.
- Assign workout.
- Diet plans.
- Calendar.
- Training sessions.
- Progress reports.
- Messages.
- Earnings.
- Profile.

MEMBER:

- Home.
- Today's workout.
- Workout details.
- Exercise video.
- Workout timer.
- Workout history.
- Exercise library.
- Diet dashboard.
- Meal planner.
- Calorie tracker.
- Water tracker.
- Body measurements.
- Progress photographs.
- Goals.
- Membership card.
- QR attendance.
- Payment history.
- Gym announcements.
- Class booking.
- Trainer communication.
- Challenges.
- Achievements.
- Personal records.
- Settings.

MARKETPLACE:

- Marketplace home.
- Nearby gyms.
- Gym details.
- Membership comparison.
- Trial booking.
- Trainer discovery.
- Trainer profile.
- Trainer booking.
- Nutritionist discovery.
- Consultation booking.
- Reviews.
- Favourites.
- My bookings.

SUPER ADMIN:

- Dashboard.
- Gym management.
- User management.
- Subscription plans.
- Revenue analytics.
- Payment monitoring.
- Gym verification.
- Marketplace moderation.
- Support tickets.
- Coupon management.
- Feature flags.
- Notifications.
- Audit logs.
- Settings.

21. MULTILINGUAL SUPPORT

Build localization from the beginning.

Initially:

- English.
- Hindi.

Architect for at least 20 languages.

All user-facing text must use localization keys.

Never hardcode UI text in widgets or components.

Support regional date, currency and number formats.

22. SECURITY AND COMPLIANCE

Implement:

- Secure authentication.
- MFA for privileged accounts.
- Role-based authorization.
- Tenant isolation.
- Database RLS.
- Input validation.
- XSS protection.
- CSRF protection where applicable.
- Secure file uploads.
- Signed media URLs.
- Payment webhook verification.
- API rate limiting.
- Audit logging.
- Backup and recovery.
- Privacy settings.
- Consent management.
- Data export.
- Data deletion.
- Retention policies.
- Incident response.

Fitness and health-related data must have stricter access controls.

Do not expose member information to trainers unless assigned and authorized.

Follow applicable Indian privacy and consumer prote