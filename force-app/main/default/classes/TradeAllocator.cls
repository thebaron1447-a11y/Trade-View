/**
 * Splits an amount across advisors by their shares, to the cent, so the parts always add up to the whole.
 *
 * Each share is rounded down (towards zero) to the cent, and the cents left over go one at a time to the largest
 * shares first (ties by the order given). Redemptions are negative and split the same way, so a 50/50 split of
 * -100.01 gives -50.01 and -50.00, and summing allocations by advisor gives net sales.
 * Pure logic, no queries or saves: TradeLoader calls it for trades and AUM balances.
 */
public with sharing class TradeAllocator {
    /** One advisor's share in, one advisor's amount out. Percent is in points: 60 means 60%. */
    public class Share {
        public Id advisorId;
        public Decimal percent;
        public Decimal amount;

        public Share(Id advisorId, Decimal percent) {
            this.advisorId = advisorId;
            this.percent = percent;
        }
    }

    /** Shares must be positive and total exactly 100. Returns the same shares with amount set. */
    public static List<Share> split(Decimal total, List<Share> shares) {
        if (total == null) {
            throw new IllegalArgumentException('There is no amount to split.');
        }
        if (shares == null || shares.isEmpty()) {
            throw new IllegalArgumentException('There is no one to credit.');
        }
        Decimal points = 0;
        for (Share s : shares) {
            if (s.percent == null || s.percent <= 0) {
                throw new IllegalArgumentException('Every share must be more than 0%.');
            }
            points += s.percent;
        }
        if (points != 100) {
            throw new IllegalArgumentException('Shares total ' + points.stripTrailingZeros().toPlainString() + '%, not 100%.');
        }
        Decimal whole = total.setScale(2, RoundingMode.HALF_UP);
        Decimal given = 0;
        for (Share s : shares) {
            s.amount = (whole * s.percent / 100).setScale(2, RoundingMode.DOWN);
            given += s.amount;
        }
        // What is left is a whole number of cents, fewer than the number of shares, with the same sign as the total.
        Integer cents = Math.abs(((whole - given) * 100).intValue());
        Decimal cent = whole < 0 ? -0.01 : 0.01;
        for (Integer i : largestFirst(shares)) {
            if (cents == 0) {
                break;
            }
            shares[i].amount += cent;
            cents--;
        }
        return shares;
    }

    /** Indexes of the shares, largest percent first; equal shares keep the order given. */
    private static List<Integer> largestFirst(List<Share> shares) {
        List<Integer> order = new List<Integer>();
        for (Integer i = 0; i < shares.size(); i++) {
            Integer at = order.size();
            for (Integer j = 0; j < order.size(); j++) {
                if (shares[i].percent > shares[order[j]].percent) {
                    at = j;
                    break;
                }
            }
            if (at == order.size()) {
                order.add(i);
            } else {
                order.add(at, i);
            }
        }
        return order;
    }
}
