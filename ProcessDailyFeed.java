import java.io.File;
import java.io.FileWriter;
import java.io.IOException; // Used to handle errors
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Scanner; // Used for reading
import java.util.List;
import java.util.Map;
import java.time.DateTimeException;
import java.time.LocalDate;
import java.util.Set;

public class ProcessDailyFeed {

    public static void main(String[] args) {
        System.out.println("Processing daily transactions...");

        // Get customers IDs
        Set<String> validCustomerIds = new HashSet<>();

        try {
            Scanner scanner = new Scanner(new File("./inbound/customers_20260625.csv"));

            if (scanner.hasNextLine()) {
                scanner.nextLine(); // skip Header
            }

            while (scanner.hasNextLine()) {
                String data = scanner.nextLine();
                String[] words = data.split(",", -1);
                validCustomerIds.add(words[0]);
            }

            scanner.close();

        } catch (IOException e) {
            System.out.println("Error: Unable to read the customers file");
            e.printStackTrace();
        }

        List<Transaction> valid_transactions = new ArrayList<>();
        List<Transaction> invalid_transactions = new ArrayList<>();
        Set<String> seenTxnIds = new HashSet<>();
        // Read transactions file
        try (Scanner reader = new Scanner(new File("./inbound/transactions_20260625.csv"))) {
            if (reader.hasNextLine()) {
                reader.nextLine(); // skipped Header
            }

            // Read it line by line
            while (reader.hasNextLine()) {
                String data = reader.nextLine();
                String[] words = data.split(",", -1);

                if (words.length != 6) {
                    System.out.println("Invalid row format: " + data);
                    continue;
                }

                Transaction transaction = new Transaction(words, validCustomerIds, seenTxnIds);

                if (transaction.isValid) {
                    valid_transactions.add(transaction);
                } else {
                    invalid_transactions.add(transaction);
                }

            }
        } catch (IOException e) {
            System.out.println("An error occurred: The file could not be opened.");
            e.printStackTrace();
        }
        System.out.println("Valid transactions: " + valid_transactions.size());
        System.out.println("Invalid transactions: " + invalid_transactions.size());

        int paidCount = 0;
        int failedCount = 0;
        int pendingCount = 0;
        int refundedCount = 0;

        for (Transaction transaction : valid_transactions) {
            switch (transaction.status) {
                case "PAID":
                    paidCount++;
                    break;
                case "FAILED":
                    failedCount++;
                    break;
                case "PENDING":
                    pendingCount++;
                    break;
                case "REFUNDED":
                    refundedCount++;
                    break;
            }
        }

        System.out.println("PAID count: " + paidCount);
        System.out.println("FAILED count: " + failedCount);
        System.out.println("PENDING count: " + pendingCount);
        System.out.println("REFUNDED count: " + refundedCount);

        // Top 5 paid customers
        Map<String, Double> paidTotalByCustomer = new HashMap<>();
        for (Transaction transaction : valid_transactions) {
            if (transaction.status.equals("PAID")) {
                paidTotalByCustomer.put(
                        transaction.customerId,
                        paidTotalByCustomer.getOrDefault(transaction.customerId, 0.0) + transaction.amount);
            }
        }

        paidTotalByCustomer.entrySet()
                .stream()
                .sorted((a, b) -> Double.compare(b.getValue(), a.getValue()))
                .limit(5)
                .forEach(entry -> System.out.println(entry.getKey() + " : " + entry.getValue()));

        // Write invalid data file
        try (FileWriter writer = new FileWriter("./invalid_transactions.csv")) {
            writer.write("date,invalid_reason,txn_id,customer_id,amount,status,source_file\n");
            for (Transaction transaction : invalid_transactions) {
                writer.write(transaction.txnDate + "," + transaction.invalidReason + "," + transaction.txnId + ","
                        + transaction.customerId + "," + transaction.amount + "," + transaction.status + ","
                        + transaction.sourceFile + "\n");
            }
        } catch (IOException e) {
            System.out.println("Error: Unable to write file");
            e.printStackTrace();
        }

    }

    // txnId,customerId,txnDate,amount,status,sourceFile
    public static class Transaction {
        String txnId;
        String customerId;
        String txnDate;
        Double amount;
        String status;
        String sourceFile;
        Boolean isValid = true;
        String invalidReason;
        private static final Set<String> VALID_STATUSES = new HashSet<>(
                Arrays.asList("PAID", "FAILED", "PENDING", "REFUNDED"));

        public Transaction(String[] words, Set<String> validCustomerIds, Set<String> seenTxnIds) {
            if (words[0].isEmpty()) {
                this.isValid = false;
                this.invalidReason = "invalid txnId: " + words[0];
            } else if (seenTxnIds.contains(words[0])) {
                this.isValid = false;
                this.invalidReason = "duplicate txnId: " + words[0];
            } else {
                seenTxnIds.add(words[0]);
            }
            this.txnId = words[0];
            if (words[1].isEmpty()) {
                this.isValid = false;
                this.invalidReason = "invalid customer ID: " + words[1];
            } else if (!validCustomerIds.contains(words[1])) {
                this.isValid = false;
                this.invalidReason = "unknown customer ID: " + words[1];
            }

            this.customerId = words[1];

            try {
                LocalDate.parse(words[2]);
            } catch (DateTimeException e) {
                this.isValid = false;
                this.invalidReason = "Bad date format";
            }
            this.txnDate = words[2];
            try {
                this.amount = Double.parseDouble(words[3]);
                if (this.amount < 0 || this.amount > 10000) {
                    this.isValid = false;
                    this.invalidReason = "Amount out of range: " + words[3];
                }
            } catch (NumberFormatException e) {
                this.isValid = false;
                this.invalidReason = "Invalid amount: " + words[3];
            }
            if (!VALID_STATUSES.contains(words[4])) {
                this.isValid = false;
                this.invalidReason = "Invalid status: " + words[4];
            }
            this.status = words[4];
            this.sourceFile = words[5];
        }

        public void getTransaction() {
            System.out.println("txnId: " + this.txnId);
            System.out.println("customerId: " + this.customerId);
            System.out.println("txnDate: " + this.txnDate);
            System.out.println("amount: " + this.amount);
            System.out.println("status: " + this.status);
            System.out.println("sourceFile: " + this.sourceFile);
        }

    }
}