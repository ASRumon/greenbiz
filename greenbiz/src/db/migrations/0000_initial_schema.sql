CREATE TABLE `credit_profiles` (
	`shop_id` text PRIMARY KEY NOT NULL,
	`score` integer NOT NULL,
	`factors` text NOT NULL,
	`monthly_revenue_avg_minor` integer NOT NULL,
	`monthly_volatility` real NOT NULL,
	`transaction_count_90d` integer NOT NULL,
	`computed_at` integer NOT NULL,
	FOREIGN KEY (`shop_id`) REFERENCES `shops`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE TABLE `financial_institutions` (
	`id` text PRIMARY KEY NOT NULL,
	`name` text NOT NULL,
	`institution_type` text NOT NULL,
	`website` text,
	`description` text,
	`contact_phone` text,
	`is_active` integer DEFAULT true NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE TABLE `financial_service_plans` (
	`id` text PRIMARY KEY NOT NULL,
	`institution_id` text NOT NULL,
	`plan_name` text NOT NULL,
	`service_type` text NOT NULL,
	`description` text,
	`min_amount_minor` integer,
	`max_amount_minor` integer,
	`interest_rate_min` real,
	`interest_rate_max` real,
	`duration_months` integer,
	`eligibility_criteria` text,
	`fees_details` text,
	`source_url` text,
	`last_verified_at` integer,
	`is_active` integer DEFAULT true NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`institution_id`) REFERENCES `financial_institutions`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `plans_institution_idx` ON `financial_service_plans` (`institution_id`);--> statement-breakpoint
CREATE INDEX `plans_service_type_idx` ON `financial_service_plans` (`service_type`);--> statement-breakpoint
CREATE TABLE `loan_applications` (
	`id` text PRIMARY KEY NOT NULL,
	`shop_id` text NOT NULL,
	`plan_id` text NOT NULL,
	`status` text DEFAULT 'draft' NOT NULL,
	`notes` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`shop_id`) REFERENCES `shops`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`plan_id`) REFERENCES `financial_service_plans`(`id`) ON UPDATE no action ON DELETE no action
);
--> statement-breakpoint
CREATE INDEX `loan_applications_shop_idx` ON `loan_applications` (`shop_id`);--> statement-breakpoint
CREATE TABLE `products` (
	`id` text PRIMARY KEY NOT NULL,
	`shop_id` text NOT NULL,
	`product_name` text NOT NULL,
	`unit` text NOT NULL,
	`unit_price_minor` integer NOT NULL,
	`stock_quantity` real DEFAULT 0 NOT NULL,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`shop_id`) REFERENCES `shops`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `products_shop_idx` ON `products` (`shop_id`);--> statement-breakpoint
CREATE TABLE `shops` (
	`id` text PRIMARY KEY NOT NULL,
	`owner_id` text NOT NULL,
	`shop_name` text NOT NULL,
	`business_type` text,
	`phone` text,
	`address` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`owner_id`) REFERENCES `users`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE INDEX `shops_owner_idx` ON `shops` (`owner_id`);--> statement-breakpoint
CREATE TABLE `sms_messages` (
	`id` text PRIMARY KEY NOT NULL,
	`shop_id` text NOT NULL,
	`sender` text NOT NULL,
	`body` text NOT NULL,
	`received_at` integer NOT NULL,
	`provider` text NOT NULL,
	`parse_status` text NOT NULL,
	`parse_error` text,
	`parse_source` text,
	`raw_extract` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`shop_id`) REFERENCES `shops`(`id`) ON UPDATE no action ON DELETE cascade
);
--> statement-breakpoint
CREATE UNIQUE INDEX `sms_messages_dedupe_idx` ON `sms_messages` (`shop_id`,`sender`,`body`,`received_at`);--> statement-breakpoint
CREATE INDEX `sms_messages_shop_received_idx` ON `sms_messages` (`shop_id`,`received_at`);--> statement-breakpoint
CREATE INDEX `sms_messages_shop_status_idx` ON `sms_messages` (`shop_id`,`parse_status`);--> statement-breakpoint
CREATE TABLE `transactions` (
	`id` text PRIMARY KEY NOT NULL,
	`shop_id` text NOT NULL,
	`sms_id` text,
	`direction` text NOT NULL,
	`amount_minor` integer NOT NULL,
	`currency` text NOT NULL,
	`counterparty` text,
	`reference` text,
	`occurred_at` integer NOT NULL,
	`note` text,
	`created_at` integer NOT NULL,
	FOREIGN KEY (`shop_id`) REFERENCES `shops`(`id`) ON UPDATE no action ON DELETE cascade,
	FOREIGN KEY (`sms_id`) REFERENCES `sms_messages`(`id`) ON UPDATE no action ON DELETE set null
);
--> statement-breakpoint
CREATE INDEX `transactions_shop_occurred_idx` ON `transactions` (`shop_id`,`occurred_at`);--> statement-breakpoint
CREATE INDEX `transactions_shop_direction_idx` ON `transactions` (`shop_id`,`direction`);--> statement-breakpoint
CREATE UNIQUE INDEX `transactions_sms_unique_idx` ON `transactions` (`sms_id`);--> statement-breakpoint
CREATE TABLE `users` (
	`id` text PRIMARY KEY NOT NULL,
	`full_name` text NOT NULL,
	`username` text NOT NULL,
	`email` text,
	`password_hash` text NOT NULL,
	`created_at` integer NOT NULL
);
--> statement-breakpoint
CREATE UNIQUE INDEX `users_username_unique` ON `users` (`username`);--> statement-breakpoint
CREATE UNIQUE INDEX `users_email_unique` ON `users` (`email`);