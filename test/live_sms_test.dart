import 'package:flutter_test/flutter_test.dart';
import 'package:greenbiz/core/sms_payment_parser.dart';
import 'package:greenbiz/models/live_sms_payment.dart';

void main() {
  group('live payment SMS parsing', () {
    test('reads a bKash received-money confirmation', () {
      final ParsedPaymentSms parsed = parsePaymentSms(
        sender: '16247',
        body:
            'You have received Tk 1,250.50 from 01712345678. '
            'TrxID 9H7ABC12. New balance Tk 5,000.00.',
        receivedAt: DateTime(2026, 10, 17, 12),
      );

      expect(parsed.isPaymentCandidate, isTrue);
      expect(parsed.isInflow, isTrue);
      expect(parsed.isReceivedMoney, isTrue);
      expect(parsed.amountMinor, 125050);
      expect(parsed.method, 'bkash');
      expect(parsed.reference, '9H7ABC12');
    });

    test('skips a balance that appears before the amount', () {
      final ParsedPaymentSms parsed = parsePaymentSms(
        sender: 'Nagad',
        body:
            'Your new balance is Tk 5,000.00. Money received: Tk 500.00 '
            'from 01712345678. TxnID NGD778812.',
        receivedAt: DateTime(2026, 10, 17, 12),
      );

      expect(parsed.amountMinor, 50000);
      expect(parsed.method, 'nagad');
      expect(parsed.reference, 'NGD778812');
    });

    test('does not treat an outgoing payment as received money', () {
      final ParsedPaymentSms parsed = parsePaymentSms(
        sender: '16247',
        body: 'You have sent Tk 300.00 to 01712345678. TrxID ABC12345.',
        receivedAt: DateTime(2026, 10, 17, 12),
      );

      expect(parsed.isPaymentCandidate, isTrue);
      expect(parsed.isInflow, isFalse);
      expect(parsed.isReceivedMoney, isFalse);
      expect(parsed.amountMinor, 30000);
    });

    test('ignores OTP messages from a payment sender', () {
      final ParsedPaymentSms parsed = parsePaymentSms(
        sender: '16247',
        body: 'Your bKash OTP is 123456. Do not share it with anyone.',
        receivedAt: DateTime(2026, 10, 17, 12),
      );

      expect(parsed.isPaymentCandidate, isFalse);
      expect(parsed.isReceivedMoney, isFalse);
    });

    test('ignores personal numbers even when they mention money', () {
      final ParsedPaymentSms parsed = parsePaymentSms(
        sender: '01712345678',
        body: 'I received Tk 500 from you, thanks!',
        receivedAt: DateTime(2026, 10, 17, 12),
      );

      expect(parsed.isPaymentCandidate, isFalse);
      expect(parsed.amountMinor, isNull);
    });

    test('recognises an Indian bank UPI credit', () {
      final ParsedPaymentSms parsed = parsePaymentSms(
        sender: 'VM-HDFCBK',
        body:
            'Rs.500.00 credited to your account ending 4321. '
            'UPI Ref 512345678901.',
        receivedAt: DateTime(2026, 10, 17, 12),
      );

      expect(parsed.isInflow, isTrue);
      expect(parsed.amountMinor, 50000);
      expect(parsed.method, 'upi');
      expect(parsed.reference, '512345678901');
    });

    test('handles every provider layout from the sample directory', () {
      final List<
        ({
          String sender,
          String body,
          String method,
          bool inflow,
          int amount,
          String? reference,
        })
      >
      cases =
          <
            ({
              String sender,
              String body,
              String method,
              bool inflow,
              int amount,
              String? reference,
            })
          >[
            (
              sender: 'bKash',
              body:
                  'You have received Tk 5,000.00 from Agent 0171X-XXXXXX. '
                  'TrxID 8G72ABC1DE at 17/10/2026 14:30. Balance Tk 5,750.00.',
              method: 'bkash',
              inflow: true,
              amount: 500000,
              reference: '8G72ABC1DE',
            ),
            (
              sender: 'bKash',
              body:
                  'Mobile Recharge Tk 200.00 to 019XXXXXXXX successful. '
                  'TrxID 8G73KLM4NP at 17/10/2026 16:15. Fee Tk 0.00. '
                  'Balance Tk 550.00.',
              method: 'bkash',
              inflow: false,
              amount: 20000,
              reference: '8G73KLM4NP',
            ),
            (
              sender: 'bKash',
              body:
                  'Payment Tk 1,200.00 to Aarong successful. '
                  'TrxID 8G74XYZ7QR at 17/10/2026 20:10. Reference: Bill01. '
                  'Balance Tk 3,450.00.',
              method: 'bkash',
              inflow: false,
              amount: 120000,
              reference: '8G74XYZ7QR',
            ),
            (
              sender: 'bKash',
              body:
                  'Bill Pay successful. Organization: DESCO Postpaid. '
                  'Account No: 100234567. Amount: Tk 2,450.00. Fee: Tk 5.00. '
                  'TrxID 8G75QWE2RT at 17/10/2026 11:05. Balance Tk 1,200.00.',
              method: 'bkash',
              inflow: false,
              amount: 245000,
              reference: '8G75QWE2RT',
            ),
            (
              sender: 'bKash',
              body:
                  'Tk 10,000.00 added to your Account from BRAC Bank '
                  'Account/Card. TrxID 8G76VBN3MK at 17/10/2026 09:12. '
                  'Balance Tk 12,300.00.',
              method: 'bkash',
              inflow: true,
              amount: 1000000,
              reference: '8G76VBN3MK',
            ),
            (
              sender: 'Nagad',
              body:
                  'Cash In of Tk 3,000.00 is successful. Agent: 0182X-XXXXXX. '
                  'TrxID: NGD88776655. Fee: Tk 0.00. Balance: Tk 4,500.00. '
                  'Date: 17/10/2026 12:40.',
              method: 'nagad',
              inflow: true,
              amount: 300000,
              reference: 'NGD88776655',
            ),
            (
              sender: 'Nagad',
              body:
                  'Mobile Recharge of Tk 50.00 to 015XXXXXXXX is successful. '
                  'TrxID: NGD44332211. Fee: Tk 0.00. Balance: Tk 450.00. '
                  'Date: 17/10/2026 13:00.',
              method: 'nagad',
              inflow: false,
              amount: 5000,
              reference: 'NGD44332211',
            ),
            (
              sender: 'Nagad',
              body:
                  'Payment of Tk 850.00 to Shwapno is successful. '
                  'TrxID: NGD11223344. Fee: Tk 0.00. Balance: Tk 1,200.00. '
                  'Date: 17/10/2026 21:15.',
              method: 'nagad',
              inflow: false,
              amount: 85000,
              reference: 'NGD11223344',
            ),
            (
              sender: 'Nagad',
              body:
                  'Bill Pay of Tk 1,800.00 to DPDC is successful. '
                  'Consumer No: 9876543. TrxID: NGD55667788. Fee: Tk 10.00. '
                  'Balance: Tk 2,100.00.',
              method: 'nagad',
              inflow: false,
              amount: 180000,
              reference: 'NGD55667788',
            ),
            (
              sender: 'Nagad',
              body:
                  'Add Money of Tk 5,000.00 from Sonali Bank is successful. '
                  'TrxID: NGD99001122. Fee: Tk 0.00. Balance: Tk 6,400.00.',
              method: 'nagad',
              inflow: true,
              amount: 500000,
              reference: 'NGD99001122',
            ),
            (
              sender: 'Rocket',
              body:
                  'Rocket: Cash-In of Tk 4,000.00 through Agent 0191X-XXXXXX '
                  'is successful. TrxID: DBBL112233. Fee: Tk 0.00. '
                  'Available Balance: Tk 5,200.00.',
              method: 'rocket',
              inflow: true,
              amount: 400000,
              reference: 'DBBL112233',
            ),
            (
              sender: 'Rocket',
              body:
                  'Rocket: Mobile Recharge of Tk 100.00 to 017XXXXXXXX is '
                  'successful. TrxID: DBBL445566. Available Balance: Tk 800.00.',
              method: 'rocket',
              inflow: false,
              amount: 10000,
              reference: 'DBBL445566',
            ),
            (
              sender: 'Rocket',
              body:
                  'Rocket: Merchant Pay of Tk 2,300.00 to Daraz Bangladesh is '
                  'successful. TrxID: DBBL778899. Available Balance: Tk 1,500.00.',
              method: 'rocket',
              inflow: false,
              amount: 230000,
              reference: 'DBBL778899',
            ),
            (
              sender: 'Rocket',
              body:
                  'Rocket: Bill Pay of Tk 3,200.00 to Dhaka WASA is successful. '
                  'Biller ID: 320. TrxID: DBBL001122. Fee: Tk 10.00. '
                  'Available Balance: Tk 900.00.',
              method: 'rocket',
              inflow: false,
              amount: 320000,
              reference: 'DBBL001122',
            ),
            (
              sender: 'Rocket',
              body:
                  'Rocket: Transfer of Tk 7,000.00 to DBBL A/C '
                  '123.XXX.XXXXX is successful. TrxID: DBBL334455. '
                  'Fee: Tk 70.00. Available Balance: Tk 1,100.00.',
              method: 'rocket',
              inflow: false,
              amount: 700000,
              reference: 'DBBL334455',
            ),
            (
              sender: 'upay',
              body:
                  'upay: Cash In Tk 2,000.00 from Agent 0161X-XXXXXX '
                  'successful. TrxID: UPY776655. Fee: Tk 0.00. '
                  'Current Balance: Tk 2,850.00. 17/10/2026 15:45.',
              method: 'upay',
              inflow: true,
              amount: 200000,
              reference: 'UPY776655',
            ),
            (
              sender: 'upay',
              body:
                  'upay: Sent Money Tk 1,500.00 to 018XXXXXXXX successful. '
                  'TrxID: UPY443322. Fee: Tk 0.00. '
                  'Current Balance: Tk 1,350.00.',
              method: 'upay',
              inflow: false,
              amount: 150000,
              reference: 'UPY443322',
            ),
            (
              sender: 'upay',
              body:
                  'upay: Cash Out Tk 1,000.00 from Agent successful. '
                  'TrxID: UPY112233. Fee: Tk 14.00. '
                  'Current Balance: Tk 336.00.',
              method: 'upay',
              inflow: false,
              amount: 100000,
              reference: 'UPY112233',
            ),
            (
              sender: 'upay',
              body:
                  'upay: Bill Pay Tk 950.00 to Titas Gas successful. '
                  'TrxID: UPY998877. Fee: Tk 5.00. '
                  'Current Balance: Tk 45.00.',
              method: 'upay',
              inflow: false,
              amount: 95000,
              reference: 'UPY998877',
            ),
            (
              sender: 'bKash',
              body:
                  'You have received payment of Tk 1,200.00 from 017XXXXXXXX. '
                  'Ref: Bill01. Counter: 1. TrxID 8G74XYZ7QR at '
                  '17/10/2026 20:10. Balance Tk 145,200.00.',
              method: 'bkash',
              inflow: true,
              amount: 120000,
              reference: '8G74XYZ7QR',
            ),
            (
              sender: 'Nagad',
              body:
                  'Merchant Pay Received of Tk 850.00 from Customer '
                  '019XXXXXXXX. TrxID: NGD11223344. Store ID: 02. '
                  'Date: 17/10/2026 21:15. Total Wallet Balance: Tk 89,450.00.',
              method: 'nagad',
              inflow: true,
              amount: 85000,
              reference: 'NGD11223344',
            ),
            (
              sender: 'Rocket',
              body:
                  'Rocket: Merchant Payment Received of Tk 2,300.00 from '
                  '015XXXXXXXX. TrxID: DBBL778899. '
                  'Available Merchant Balance: Tk 312,800.00.',
              method: 'rocket',
              inflow: true,
              amount: 230000,
              reference: 'DBBL778899',
            ),
            (
              sender: 'upay',
              body:
                  'upay: Collection of Tk 950.00 from 016XXXXXXXX successful. '
                  'TrxID: UPY998877. Current Merchant Balance: Tk 42,150.00.',
              method: 'upay',
              inflow: true,
              amount: 95000,
              reference: 'UPY998877',
            ),
          ];

      for (final ({
            String sender,
            String body,
            String method,
            bool inflow,
            int amount,
            String? reference,
          })
          item
          in cases) {
        final ParsedPaymentSms parsed = parsePaymentSms(
          sender: item.sender,
          body: item.body,
          receivedAt: DateTime(2026, 10, 17),
        );

        expect(parsed.method, item.method, reason: item.body);
        expect(parsed.isInflow, item.inflow, reason: item.body);
        expect(parsed.amountMinor, item.amount, reason: item.body);
        expect(parsed.reference, item.reference, reason: item.body);
      }
    });

    test('survives future wording changes', () {
      final ParsedPaymentSms credited = parsePaymentSms(
        sender: '64444',
        body:
            'Payment credited: Tk 1,234.00 from 017XXXXXXXX via bKash. '
            'Txn ID ABC12345. Balance Tk 9,000.00.',
        receivedAt: DateTime(2026, 10, 17),
      );
      expect(credited.method, 'bkash');
      expect(credited.isInflow, isTrue);
      expect(credited.amountMinor, 123400);
      expect(credited.reference, 'ABC12345');

      final ParsedPaymentSms bill = parsePaymentSms(
        sender: 'upay',
        body:
            'upay: Bill payment completed. Amount: Tk 300.00. Fee: Tk 2.00. '
            'TrxID UPY102030.',
        receivedAt: DateTime(2026, 10, 17),
      );
      expect(bill.isInflow, isFalse);
      expect(bill.amountMinor, 30000);
      expect(bill.reference, 'UPY102030');
    });

    test('builds a live payment from the native map', () {
      final LiveSmsPayment payment = LiveSmsPayment.fromNative(
        <dynamic, dynamic>{
          'id': 'abc',
          'sender': '16248',
          'body': 'Money received Tk 1,000.00. TrxID NAG123456.',
          'receivedAt': 1760000000000,
          'amountMinor': 1,
          'method': 'other',
        },
      );

      expect(payment.id, 'abc');
      expect(payment.amountMinor, 100000);
      expect(payment.method, 'nagad');
      expect(payment.reference, 'NAG123456');
      expect(payment.isInflow, isTrue);
    });
  });
}
