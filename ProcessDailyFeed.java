
// 1. Read transactions CSV
// 2. Read customers CSV
// 3. Validate rows
// 4. Count valid/rejected rows
// 5. Count statuses
// 6. Print top 5 paid customers
import java.io.File;
import java.io.FileWriter; // Used for writing
import java.io.IOException; // Used to handle errors
import java.util.ArrayList;
import java.util.Scanner; // Used for reading
import java.util.List;
import java.util.ArrayList;
import java.time.DateTimeException;
import java.time.LocalDate;

public class ProcessDailyFeed {

    public static void main(String[] args) {
        System.out.println("Processing daily transactions...");

        List<Transaction> transactions = new ArrayList<>();
        // Read transactions file
        try {
            Scanner reader = new Scanner(new File("./inbound/transactions_20260625.csv"));

            if (reader.hasNextLine()) {
                String header = reader.nextLine();
                System.out.println("Skipped Header: " + header);
            }

            // Read it line by line
            while (reader.hasNextLine()) {
                String data = reader.nextLine();
                String[] words = data.split(",");

                Transaction transaction = new Transaction(words);

                transactions.add(transaction);
            }
            // close the reader
            reader.close();
            for (Transaction tran : transactions) {
                tran.getTransaction();
            }

        } catch (IOException e) {
            System.out.println("An error occurred: The file could not be opened.");
            e.printStackTrace();
        }

    }

    // txn_id,customer_id,txn_date,amount,status,source_file
    public static class Transaction {
        String txn_id;
        String customer_id;
        String txn_date;
        Double amount;
        String status;
        String source_file;
        Boolean valid_transaction = true;
        String invalid_reason;

        public Transaction(String[] words) {
            if (words[0].isEmpty()) {
                this.valid_transaction = false;
                this.invalid_reason = "invalid txn_id: " + words[0];
            }
            this.txn_id = words[0];
            if (words[1].isEmpty()) {
                this.valid_transaction = false;
                this.invalid_reason = "invalid customer ID: " + words[1];
            }
            this.customer_id = words[1];

            try {
                LocalDate.parse(words[2]);
            } catch (DateTimeException e) {
                this.valid_transaction = false;
                this.invalid_reason = "Bad date format";
            }
            this.txn_date = words[2];
            try {
                this.amount = Double.parseDouble(words[3]);
            } catch (NumberFormatException e) {
                this.valid_transaction = false;
                this.invalid_reason = "Invalid number: " + words[3];
            }
            this.status = words[4];
            this.source_file = words[5];
        }

        public void getTransaction() {
            System.out.println(this.txn_id);
            System.out.println(this.customer_id);
            System.out.println(this.txn_date);
            System.out.println(this.amount);
            System.out.println(this.status);
            System.out.println(this.source_file);
        }

    }
}
